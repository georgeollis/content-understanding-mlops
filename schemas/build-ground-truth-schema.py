"""
Builds a JSON Schema for a family's ground-truth "*.expected.json" files, derived directly
from that family's analyzer.json fieldSchema (not hand-written), so a typo'd or renamed field
in expected.json fails loudly instead of silently scoring as "missing" in compare-analyzers.ps1.

Usage:
  python build-ground-truth-schema.py <family>          # e.g. invoice
  python build-ground-truth-schema.py --all              # every analyzers/*/analyzer.json

Writes: analyzers/<family>/golden/expected.schema.json
"""
import argparse
import json
import os

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ANALYZERS_DIR = os.path.join(REPO_ROOT, "analyzers")

# Maps Content Understanding ContentFieldType -> JSON Schema type for ground-truth values.
# date/time are represented as plain strings in our expected.json ground truth (ISO date strings).
SIMPLE_TYPE_MAP = {
    "string": "string",
    "date": "string",
    "time": "string",
    "number": "number",
    "integer": "integer",
    "boolean": "boolean",
}


def field_def_to_schema(field_def):
    ftype = field_def.get("type")
    description = field_def.get("description")

    if ftype in SIMPLE_TYPE_MAP:
        schema = {"type": SIMPLE_TYPE_MAP[ftype]}
    elif ftype == "array":
        items_def = field_def.get("items", {})
        schema = {"type": "array", "items": field_def_to_schema(items_def)}
    elif ftype == "object":
        props = field_def.get("properties", {})
        schema = {
            "type": "object",
            "properties": {name: field_def_to_schema(d) for name, d in props.items()},
            "required": list(props.keys()),
        }
    elif ftype == "json":
        schema = {}
    else:
        schema = {}

    if description:
        schema["description"] = description
    return schema


def build_schema_for_family(family):
    analyzer_path = os.path.join(ANALYZERS_DIR, family, "analyzer.json")
    if not os.path.exists(analyzer_path):
        raise FileNotFoundError(f"No analyzer.json found for family '{family}' at {analyzer_path}")

    with open(analyzer_path, "r", encoding="utf-8") as f:
        analyzer = json.load(f)

    fields = analyzer.get("fieldSchema", {}).get("fields", {})
    properties = {name: field_def_to_schema(d) for name, d in fields.items()}

    schema = {
        "$schema": "http://json-schema.org/draft-04/schema#",
        "title": f"{family} ground-truth (expected.json) schema",
        "description": (
            f"Auto-generated from analyzers/{family}/analyzer.json. Do not hand-edit; "
            f"re-run build-ground-truth-schema.py after changing the analyzer's fieldSchema."
        ),
        "type": "object",
        "properties": properties,
        "required": list(properties.keys()),
        "additionalProperties": False,
    }

    golden_dir = os.path.join(ANALYZERS_DIR, family, "golden")
    os.makedirs(golden_dir, exist_ok=True)
    out_path = os.path.join(golden_dir, "expected.schema.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(schema, f, indent=2)

    print(f"Wrote {out_path} ({len(properties)} fields)")
    return out_path


def all_families():
    return sorted(
        name for name in os.listdir(ANALYZERS_DIR)
        if os.path.isfile(os.path.join(ANALYZERS_DIR, name, "analyzer.json"))
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("family", nargs="?", help="Analyzer family folder name, e.g. invoice")
    parser.add_argument("--all", action="store_true", help="Build for every family under analyzers/")
    args = parser.parse_args()

    if args.all:
        for family in all_families():
            build_schema_for_family(family)
    elif args.family:
        build_schema_for_family(args.family)
    else:
        parser.error("Provide a family name or --all")


if __name__ == "__main__":
    main()
