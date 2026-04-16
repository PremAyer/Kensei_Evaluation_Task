#!/usr/bin/env python3
"""Fix microsoft__pyright multi-PR instance_ids to single-PR format.

Three layers:
1. Dataset JSONL: instance_id multi-PR → single-PR (org__repo-{number})
2. Directory renames: eval_outputs dirs + .instance_jsonls files
3. File contents: Replace multi-PR strings in metadata.json, output.jsonl,
   output.critic_attempt_1.jsonl, pass_at_8_summary.json
"""

import json
import os
import shutil
import sys
from pathlib import Path

DATASET_PATH = Path("datasets/microsoft__pyright_resolved.jsonl")
EVAL_OUTPUTS_DIR = Path("eval_outputs")
INSTANCE_JSONLS_DIR = EVAL_OUTPUTS_DIR / ".instance_jsonls"


def build_mapping() -> dict[str, tuple[str, int]]:
    """Build mapping from old multi-PR instance_id → (new single-PR instance_id, number)."""
    mapping: dict[str, tuple[str, int]] = {}
    with open(DATASET_PATH) as f:
        for line in f:
            d = json.loads(line)
            old_id = d["instance_id"]
            number = d["number"]
            new_id = f"microsoft__pyright-{number}"
            if old_id != new_id:
                mapping[old_id] = (new_id, number)
    return mapping


def fix_dataset(mapping: dict[str, tuple[str, int]]) -> int:
    """Layer 1: Fix instance_id in dataset JSONL."""
    fixed = 0
    lines = []
    with open(DATASET_PATH) as f:
        for line in f:
            d = json.loads(line)
            old_id = d["instance_id"]
            if old_id in mapping:
                new_id = mapping[old_id][0]
                d["instance_id"] = new_id
                fixed += 1
            lines.append(json.dumps(d, ensure_ascii=False))

    with open(DATASET_PATH, "w") as f:
        f.write("\n".join(lines) + "\n")

    return fixed


def fix_file_contents(file_path: Path, old_id: str, new_id: str) -> int:
    """Replace old_id with new_id in a file. Returns number of replacements."""
    try:
        content = file_path.read_text()
    except Exception as e:
        print(f"  WARNING: Could not read {file_path}: {e}")
        return 0

    if old_id not in content:
        return 0

    new_content = content.replace(old_id, new_id)
    count = content.count(old_id)
    file_path.write_text(new_content)
    return count


def fix_eval_outputs(mapping: dict[str, tuple[str, int]]) -> tuple[int, int, int]:
    """Layer 2+3: Rename dirs/files and fix file contents."""
    dirs_renamed = 0
    files_renamed = 0
    content_replacements = 0

    for old_id, (new_id, _number) in sorted(mapping.items()):
        old_dir = EVAL_OUTPUTS_DIR / old_id
        new_dir = EVAL_OUTPUTS_DIR / new_id

        if old_dir.exists():
            if new_dir.exists():
                new_contents = list(new_dir.iterdir())
                if len(new_contents) == 0 or (
                    len(new_contents) == 1 and new_contents[0].name == "runner.log"
                ):
                    print(f"  Removing collision dir {new_dir} (empty/runner-only)")
                    shutil.rmtree(new_dir)
                else:
                    print(
                        f"  ERROR: Collision at {new_dir} with real content! Skipping."
                    )
                    continue

            for root, _dirs, filenames in os.walk(old_dir):
                for fname in filenames:
                    fpath = Path(root) / fname
                    if fname in (
                        "metadata.json",
                        "output.jsonl",
                        "output.critic_attempt_1.jsonl",
                        "pass_at_8_summary.json",
                    ):
                        count = fix_file_contents(fpath, old_id, new_id)
                        if count > 0:
                            content_replacements += count

            old_dir.rename(new_dir)
            dirs_renamed += 1
            print(f"  Renamed dir: {old_id} → {new_id}")
        else:
            print(f"  SKIP dir (not found): {old_id}")

        old_jsonl = INSTANCE_JSONLS_DIR / f"{old_id}.jsonl"
        new_jsonl = INSTANCE_JSONLS_DIR / f"{new_id}.jsonl"

        if old_jsonl.exists():
            count = fix_file_contents(old_jsonl, old_id, new_id)
            if count > 0:
                content_replacements += count

            if new_jsonl.exists():
                new_jsonl.unlink()
            old_jsonl.rename(new_jsonl)
            files_renamed += 1
            print(f"  Renamed jsonl: {old_id}.jsonl → {new_id}.jsonl")
        else:
            print(f"  SKIP jsonl (not found): {old_id}.jsonl")

    return dirs_renamed, files_renamed, content_replacements


def validate(mapping: dict[str, tuple[str, int]]) -> bool:
    """Validate all fixes were applied correctly."""
    errors = 0

    with open(DATASET_PATH) as f:
        for i, line in enumerate(f, 1):
            d = json.loads(line)
            inst_id = d["instance_id"]
            number = d["number"]
            expected = f"microsoft__pyright-{number}"
            if inst_id != expected:
                print(f"  FAIL: Line {i} instance_id={inst_id}, expected={expected}")
                errors += 1

    for _old_id, (new_id, _number) in mapping.items():
        new_dir = EVAL_OUTPUTS_DIR / new_id
        if not new_dir.exists():
            print(f"  FAIL: Expected dir {new_dir} does not exist")
            errors += 1

    for old_id in mapping:
        old_dir = EVAL_OUTPUTS_DIR / old_id
        if old_dir.exists():
            print(f"  FAIL: Old dir still exists: {old_dir}")
            errors += 1

    for old_id, (new_id, _number) in mapping.items():
        new_jsonl = INSTANCE_JSONLS_DIR / f"{new_id}.jsonl"
        old_jsonl = INSTANCE_JSONLS_DIR / f"{old_id}.jsonl"
        if not new_jsonl.exists():
            print(f"  FAIL: Expected jsonl {new_jsonl} does not exist")
            errors += 1
        if old_jsonl.exists():
            print(f"  FAIL: Old jsonl still exists: {old_jsonl}")
            errors += 1

    sample_count = 0
    for _old_id, (new_id, _number) in list(mapping.items())[:3]:
        new_dir = EVAL_OUTPUTS_DIR / new_id
        if new_dir.exists():
            for root, _dirs, filenames in os.walk(new_dir):
                for fname in filenames:
                    if fname in (
                        "metadata.json",
                        "output.jsonl",
                        "output.critic_attempt_1.jsonl",
                        "pass_at_8_summary.json",
                    ):
                        content = (Path(root) / fname).read_text()
                        if _old_id in content:
                            print(f"  FAIL: Old ID still in {Path(root) / fname}")
                            errors += 1
                        sample_count += 1

    print(f"  Spot-checked {sample_count} files for residual old IDs")

    if errors == 0:
        print("  ✓ All validations passed!")
        return True
    else:
        print(f"  ✗ {errors} validation errors found")
        return False


def main() -> None:
    print("=== Pyright Multi-PR Instance ID Fix ===\n")

    print("Building mapping...")
    mapping = build_mapping()
    print(f"  Found {len(mapping)} entries to fix\n")

    if not mapping:
        print("Nothing to fix!")
        return

    if "--dry-run" in sys.argv:
        print("DRY RUN — showing mapping only:")
        for old_id, (new_id, number) in sorted(mapping.items()):
            print(f"  {old_id} → {new_id} (PR #{number})")
        return

    print("Layer 1: Fixing dataset JSONL...")
    fixed = fix_dataset(mapping)
    print(f"  Fixed {fixed} entries\n")

    print("Layer 2+3: Fixing eval_outputs (dirs, files, contents)...")
    dirs_renamed, files_renamed, content_replacements = fix_eval_outputs(mapping)
    print(f"\n  Dirs renamed: {dirs_renamed}")
    print(f"  Files renamed: {files_renamed}")
    print(f"  Content replacements: {content_replacements}\n")

    print("Validating...")
    validate(mapping)


if __name__ == "__main__":
    main()
