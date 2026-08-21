"""
Validates a family's golden test-data set:
  1. Every "<name>.expected.json" conforms to analyzers/<family>/golden/expected.schema.json
     (auto-derived from analyzer.json's fieldSchema - catches typo'd/renamed fields).
  2. Every file's sha256 matches analyzers/<family>/golden/manifest.json (catches silent edits,
     corruption, or the manifest being stale after someone changed a golden doc).
  3. manifest.json's document list matches what's actually on disk (catches added/removed docs
     that the manifest wasn't regenerated for).

Usage:
  python validate-golden.py <family>       # e.g. invoice
  python validate-golden.py --all

Exit code is non-zero if any check fails (usable as a CI gate / pre-commit hook).

If you've intentionally added/removed/edited golden docs, re-run:
  python build-golden-manifest.py <family>
  python build-ground-truth-schema.py <family>   (only needed if the analyzer's fields changed)
"""
import argparse
import hashlib
import json
import os
import sys
from jsonschema import Draft4Validator

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ANALYZERS_DIR = os.path.join(REPO_ROOT, "analyzers")


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def all_families():
    return sorted(
        name for name in os.listdir(ANALYZERS_DIR)
        if os.path.isdir(os.path.join(ANALYZERS_DIR, name, "golden"))
    )


def validate_family(family):
    golden_dir = os.path.join(ANALYZERS_DIR, family, "golden")
    manifest_path = os.path.join(golden_dir, "manifest.json")
    schema_path = os.path.join(golden_dir, "expected.schema.json")

    errors = []

    if not os.path.exists(manifest_path):
        return [f"Missing {manifest_path} - run build-golden-manifest.py {family}"]
    if not os.path.exists(schema_path):
        return [f"Missing {schema_path} - run build-ground-truth-schema.py {family}"]

    with open(manifest_path, "r", encoding="utf-8") as f:
        manifest = json.load(f)
    with open(schema_path, "r", encoding="utf-8") as f:
        gt_schema = json.load(f)

    validator = Draft4Validator(gt_schema)

    manifest_names = {doc["name"] for doc in manifest["documents"]}
    disk_names = {
        os.path.splitext(f)[0] for f in os.listdir(golden_dir) if f.lower().endswith(".pdf")
    }

    for missing in disk_names - manifest_names:
        errors.append(f"{missing}: on disk but not in manifest.json - re-run build-golden-manifest.py {family}")
    for stale in manifest_names - disk_names:
        errors.append(f"{stale}: in manifest.json but PDF missing on disk")

    for doc in manifest["documents"]:
        name = doc["name"]
        pdf_path = os.path.join(golden_dir, doc["pdf"])
        expected_path = os.path.join(golden_dir, doc["expected"])

        if not os.path.exists(pdf_path):
            errors.append(f"{name}: {doc['pdf']} not found")
            continue
        if not os.path.exists(expected_path):
            errors.append(f"{name}: {doc['expected']} not found")
            continue

        actual_pdf_sha = sha256_of(pdf_path)
        if actual_pdf_sha != doc["pdfSha256"]:
            errors.append(f"{name}: {doc['pdf']} checksum mismatch (file changed since manifest was built)")

        actual_expected_sha = sha256_of(expected_path)
        if actual_expected_sha != doc["expectedSha256"]:
            errors.append(f"{name}: {doc['expected']} checksum mismatch (file changed since manifest was built)")

        with open(expected_path, "r", encoding="utf-8") as f:
            expected_data = json.load(f)
        schema_errors = list(validator.iter_errors(expected_data))
        for e in schema_errors:
            errors.append(f"{name}: {doc['expected']} schema error at {list(e.path)}: {e.message}")

    return errors


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("family", nargs="?")
    parser.add_argument("--all", action="store_true")
    args = parser.parse_args()

    if not args.all and not args.family:
        parser.error("Provide a family name or --all")

    families = all_families() if args.all else [args.family]

    had_errors = False
    for family in families:
        errors = validate_family(family)
        if errors:
            had_errors = True
            print(f"FAIL {family}/golden: {len(errors)} issue(s)")
            for e in errors:
                print(f"  - {e}")
        else:
            print(f"OK   {family}/golden")

    sys.exit(1 if had_errors else 0)


if __name__ == "__main__":
    main()
