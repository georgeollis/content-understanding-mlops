"""
Validates every analyzers/<family>/analyzer.json against schemas/analyzer.schema.json.

Usage:
  python validate-analyzers.py            # validate all families
  python validate-analyzers.py invoice

Exit code is non-zero if any file fails validation (usable as a CI gate / pre-commit hook).
"""
import argparse
import json
import os
import sys
from jsonschema import Draft4Validator

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ANALYZERS_DIR = os.path.join(REPO_ROOT, "analyzers")
SCHEMA_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "analyzer.schema.json")


def all_families():
    return sorted(
        name for name in os.listdir(ANALYZERS_DIR)
        if os.path.isfile(os.path.join(ANALYZERS_DIR, name, "analyzer.json"))
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("family", nargs="?", help="Validate only this family; omit to validate all")
    args = parser.parse_args()

    with open(SCHEMA_PATH, "r", encoding="utf-8") as f:
        schema = json.load(f)
    validator = Draft4Validator(schema)

    families = [args.family] if args.family else all_families()

    had_errors = False
    for family in families:
        path = os.path.join(ANALYZERS_DIR, family, "analyzer.json")
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        errors = list(validator.iter_errors(data))
        if errors:
            had_errors = True
            print(f"FAIL {family}/analyzer.json: {len(errors)} error(s)")
            for e in errors:
                print(f"  - {list(e.path)}: {e.message}")
        else:
            print(f"OK   {family}/analyzer.json")

    sys.exit(1 if had_errors else 0)


if __name__ == "__main__":
    main()
