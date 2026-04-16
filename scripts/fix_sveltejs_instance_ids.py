#!/usr/bin/env python3
"""Fix sveltejs__kit multi-PR instance_ids to single-PR format.

Dirs are already renamed to single-PR. This script fixes:
1. Dataset JSONL instance_ids
2. .instance_jsonls file renames
3. File contents (all files referencing multi-PR strings)
"""

import json
import os
import sys
from pathlib import Path

DATASET_PATH = Path("datasets/svetjs_kit.jsonl")
EVAL_OUTPUTS_DIR = Path("eval_outputs")
INSTANCE_JSONLS_DIR = EVAL_OUTPUTS_DIR / ".instance_jsonls"


def build_mapping() -> dict[str, tuple[str, int]]:
    mapping: dict[str, tuple[str, int]] = {}
    with open(DATASET_PATH) as f:
        for line in f:
            d = json.loads(line)
            old_id = d["instance_id"]
            number = d["number"]
            new_id = f"sveltejs__kit-{number}"
            if old_id != new_id:
                mapping[old_id] = (new_id, number)
    return mapping


def fix_dataset(mapping: dict[str, tuple[str, int]]) -> int:
    fixed = 0
    lines = []
    with open(DATASET_PATH) as f:
        for line in f:
            d = json.loads(line)
            old_id = d["instance_id"]
            if old_id in mapping:
                d["instance_id"] = mapping[old_id][0]
                fixed += 1
            lines.append(json.dumps(d, ensure_ascii=False))

    with open(DATASET_PATH, "w") as f:
        f.write("\n".join(lines) + "\n")

    return fixed


def fix_file_contents(file_path: Path, old_id: str, new_id: str) -> int:
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


def fix_eval_outputs(mapping: dict[str, tuple[str, int]]) -> tuple[int, int]:
    files_renamed = 0
    content_replacements = 0

    for old_id, (new_id, number) in sorted(mapping.items()):
        single_pr_dir = EVAL_OUTPUTS_DIR / new_id

        if single_pr_dir.exists():
            for root, _dirs, filenames in os.walk(single_pr_dir):
                for fname in filenames:
                    fpath = Path(root) / fname
                    count = fix_file_contents(fpath, old_id, new_id)
                    if count > 0:
                        content_replacements += count
            print(f"  Fixed contents in dir: {new_id}")
        else:
            print(f"  SKIP dir (not found): {new_id}")

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

    return files_renamed, content_replacements


def validate(mapping: dict[str, tuple[str, int]]) -> bool:
    errors = 0

    with open(DATASET_PATH) as f:
        for i, line in enumerate(f, 1):
            d = json.loads(line)
            inst_id = d["instance_id"]
            number = d["number"]
            expected = f"sveltejs__kit-{number}"
            if inst_id != expected:
                print(f"  FAIL: Line {i} instance_id={inst_id}, expected={expected}")
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
    for old_id, (new_id, _number) in list(mapping.items())[:3]:
        target_dir = EVAL_OUTPUTS_DIR / new_id
        if target_dir.exists():
            for root, _dirs, filenames in os.walk(target_dir):
                for fname in filenames:
                    fpath = Path(root) / fname
                    try:
                        content = fpath.read_text()
                        if old_id in content:
                            print(f"  FAIL: Old ID still in {fpath}")
                            errors += 1
                        sample_count += 1
                    except Exception:
                        pass

    print(f"  Spot-checked {sample_count} files for residual old IDs")

    if errors == 0:
        print("  ✓ All validations passed!")
        return True
    else:
        print(f"  ✗ {errors} validation errors found")
        return False


def main() -> None:
    print("=== SvelteJS/Kit Multi-PR Instance ID Fix ===\n")

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

    print("Layer 2+3: Fixing .instance_jsonls + file contents...")
    files_renamed, content_replacements = fix_eval_outputs(mapping)
    print(f"\n  Files renamed: {files_renamed}")
    print(f"  Content replacements: {content_replacements}\n")

    print("Validating...")
    validate(mapping)


if __name__ == "__main__":
    main()
