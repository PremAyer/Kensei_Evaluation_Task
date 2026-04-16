#!/usr/bin/env python3

import json
import sys
from pathlib import Path

from fix_dataset import fix_entry, fix_resolved_issues, load_entries


CANONICAL_KEYS = {
    "base",
    "body",
    "f2p_tests",
    "fix_patch",
    "fix_patch_result",
    "fixed_tests",
    "hints_text",
    "instance_id",
    "lang",
    "language",
    "n2p_tests",
    "number",
    "org",
    "p2p_tests",
    "pr_url",
    "prs_in_bundle",
    "repo",
    "resolved_issues",
    "run_result",
    "s2p_tests",
    "state",
    "test_patch",
    "test_patch_result",
    "title",
}


def fix_resolved_issues_type(entry: dict) -> dict:
    """resolved_issues must be list[dict] for format_data_for_inference()[0] index access.

    New datasets have it as a plain dict — wrap in list.
    """
    ri = entry.get("resolved_issues")
    if isinstance(ri, dict):
        entry["resolved_issues"] = [ri]
        return entry
    if ri is None:
        entry["resolved_issues"] = []
    return entry


def fix_instance_id(entry: dict) -> dict:
    if entry.get("instance_id"):
        return entry
    org = entry.get("org", "")
    repo = entry.get("repo", "")
    number = entry.get("number", "")
    if org and repo and number:
        entry["instance_id"] = f"{org}__{repo}-{number}"
    return entry


def fix_language(entry: dict) -> dict:
    if entry.get("language"):
        return entry
    lang = entry.get("lang", "")
    if lang:
        entry["language"] = lang
    return entry


def fix_hints_text(entry: dict) -> dict:
    if entry.get("hints_text") is None:
        entry["hints_text"] = ""
    return entry


def fix_pr_url(entry: dict) -> dict:
    if entry.get("pr_url"):
        return entry
    org = entry.get("org", "")
    repo = entry.get("repo", "")
    number = entry.get("number", "")
    if org and repo and number:
        entry["pr_url"] = f"https://github.com/{org}/{repo}/pull/{number}"
    return entry


def fix_prs_in_bundle(entry: dict) -> dict:
    """resolved_issues[0]["number"] is hyphen-separated PR numbers (e.g. "25859-25866") → list[int]."""
    if entry.get("prs_in_bundle"):
        return entry
    ri = entry.get("resolved_issues", [])
    if isinstance(ri, list) and len(ri) > 0:
        number_str = str(ri[0].get("number", ""))
    elif isinstance(ri, dict):
        number_str = str(ri.get("number", ""))
    else:
        number_str = ""

    if number_str and "-" in number_str:
        try:
            entry["prs_in_bundle"] = [int(n) for n in number_str.split("-") if n]
        except ValueError:
            number = entry.get("number")
            entry["prs_in_bundle"] = [number] if number else []
    elif number_str:
        try:
            entry["prs_in_bundle"] = [int(number_str)]
        except ValueError:
            number = entry.get("number")
            entry["prs_in_bundle"] = [number] if number else []
    else:
        number = entry.get("number")
        entry["prs_in_bundle"] = [number] if number else []
    return entry


def fix_all(entry: dict) -> dict:
    entry = fix_resolved_issues_type(entry)
    entry = fix_instance_id(entry)
    entry = fix_prs_in_bundle(entry)
    entry = fix_language(entry)
    entry = fix_hints_text(entry)
    entry = fix_pr_url(entry)
    entry = fix_entry(entry)
    entry = fix_resolved_issues(entry)
    return entry


def validate_entry(entry: dict, index: int) -> list[str]:
    warnings = []
    iid = entry.get("instance_id", f"entry_{index}")

    missing = CANONICAL_KEYS - set(entry.keys())
    if missing:
        warnings.append(f"  [{iid}] Missing canonical keys: {sorted(missing)}")

    ri = entry.get("resolved_issues")
    if not isinstance(ri, list):
        warnings.append(
            f"  [{iid}] resolved_issues is {type(ri).__name__}, expected list"
        )

    pib = entry.get("prs_in_bundle")
    if not isinstance(pib, list):
        warnings.append(
            f"  [{iid}] prs_in_bundle is {type(pib).__name__}, expected list"
        )

    return warnings


def main() -> None:
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <input.jsonl> [output.jsonl]")
        sys.exit(1)

    input_path = Path(sys.argv[1])
    output_path = Path(sys.argv[2]) if len(sys.argv) > 2 else input_path

    entries = load_entries(input_path)
    print(f"Loaded {len(entries)} entries from {input_path}")

    fixed_entries = []
    all_warnings: list[str] = []

    for i, entry in enumerate(entries):
        old_keys = set(entry.keys())
        entry = fix_all(entry)
        new_keys = set(entry.keys())

        added = new_keys - old_keys
        if added:
            iid = entry.get("instance_id", f"entry_{i}")
            print(f"  [{iid}] Added keys: {sorted(added)}")

        warnings = validate_entry(entry, i)
        all_warnings.extend(warnings)
        fixed_entries.append(entry)

    if all_warnings:
        print("\nValidation warnings:")
        for w in all_warnings:
            print(w)
    else:
        print("\nAll entries pass validation ✓")

    with open(output_path, "w", encoding="utf-8") as f:
        for entry in fixed_entries:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")

    print(f"\nWrote {len(fixed_entries)} entries to {output_path}")


if __name__ == "__main__":
    main()
