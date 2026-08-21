"""
Prints (and can rewrite into analyzers/README.md) a summary index of every analyzer family:
description, currently-live analyzerId, and golden document count.

Usage:
  python list-families.py                 # print table to stdout
  python list-families.py --write-readme  # also update the table in analyzers/README.md
"""
import argparse
import json
import os
import re

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ANALYZERS_DIR = os.path.join(REPO_ROOT, "analyzers")
README_PATH = os.path.join(ANALYZERS_DIR, "README.md")

TABLE_START = "<!-- Regenerate this table with: python schemas/list-families.py -->"


def load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def collect_rows():
    rows = []
    for family in sorted(os.listdir(ANALYZERS_DIR)):
        family_dir = os.path.join(ANALYZERS_DIR, family)
        manifest_path = os.path.join(family_dir, "manifest.json")
        if not os.path.isfile(manifest_path):
            continue

        manifest = load_json(manifest_path)
        current = manifest.get("current") or "_(not deployed)_"

        golden_manifest_path = os.path.join(family_dir, "golden", "manifest.json")
        golden_count = "0"
        if os.path.isfile(golden_manifest_path):
            golden_count = str(load_json(golden_manifest_path).get("documentCount", 0))

        rows.append((family, manifest.get("description", ""), current, golden_count))
    return rows


def render_table(rows):
    lines = ["| Family | Description | Current (live) | Golden docs |", "|---|---|---|---|"]
    for family, description, current, golden_count in rows:
        lines.append(f"| `{family}` | {description} | `{current}` | {golden_count} |")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--write-readme", action="store_true")
    args = parser.parse_args()

    rows = collect_rows()
    table = render_table(rows)
    print(table)

    if args.write_readme:
        with open(README_PATH, "r", encoding="utf-8") as f:
            content = f.read()

        pattern = re.compile(
            re.escape(TABLE_START) + r"\n\n(\|.*\n)+", re.MULTILINE
        )
        replacement = TABLE_START + "\n\n" + table + "\n"
        new_content, count = pattern.subn(replacement, content)
        if count == 0:
            raise RuntimeError(f"Could not find table marker in {README_PATH}")

        with open(README_PATH, "w", encoding="utf-8") as f:
            f.write(new_content)
        print(f"\nUpdated {README_PATH}")


if __name__ == "__main__":
    main()
