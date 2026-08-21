"""
Builds a standalone, self-contained JSON Schema for Content Understanding analyzer
definitions (the request body used by upload-analyzers.ps1), extracted from the
official Swagger/OpenAPI spec published in Azure/azure-rest-api-specs.

Source:
  specification/ai/data-plane/ContentUnderstanding/stable/2025-11-01/ContentUnderstanding.json
  (Swagger 2.0, generated from the TypeSpec source of truth)

Usage:
  python build-analyzer-schema.py

Reads:  %TEMP%\\ContentUnderstanding.swagger.json  (auto-downloaded from the source repo if missing)
Writes: schemas/analyzer.schema.json
"""
import json
import os
import tempfile
import urllib.request

SWAGGER_PATH = os.path.join(tempfile.gettempdir(), "ContentUnderstanding.swagger.json")
OUTPUT_PATH = os.path.join(os.path.dirname(__file__), "analyzer.schema.json")
SWAGGER_URL = (
    "https://raw.githubusercontent.com/Azure/azure-rest-api-specs/main/"
    "specification/ai/data-plane/ContentUnderstanding/stable/2025-11-01/ContentUnderstanding.json"
)

ROOT_DEFINITION = "ContentAnalyzer"


def ensure_swagger_downloaded():
    if os.path.exists(SWAGGER_PATH):
        return
    print(f"Downloading swagger spec from {SWAGGER_URL} ...")
    urllib.request.urlretrieve(SWAGGER_URL, SWAGGER_PATH)
    print(f"Saved to {SWAGGER_PATH}")

# Properties that only make sense on the server-returned resource (readOnly / computed),
# not on the local analyzer JSON files we author and PUT to the service.
READ_ONLY_PROPS_TO_DROP = {"analyzerId", "status", "createdAt", "lastModifiedAt", "warnings", "supportedModels"}


def collect_refs(node, defs, collected):
    """Recursively walk a schema node, collecting every #/definitions/X it references."""
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "$ref" and isinstance(value, str) and value.startswith("#/definitions/"):
                name = value.split("/")[-1]
                if name not in collected:
                    collected.add(name)
                    if name in defs:
                        collect_refs(defs[name], defs, collected)
            else:
                collect_refs(value, defs, collected)
    elif isinstance(node, list):
        for item in node:
            collect_refs(item, defs, collected)


def main():
    ensure_swagger_downloaded()
    with open(SWAGGER_PATH, "r", encoding="utf-8") as f:
        swagger = json.load(f)

    defs = swagger["definitions"]
    root = defs[ROOT_DEFINITION]

    collected = {ROOT_DEFINITION}
    collect_refs(root, defs, collected)

    out_defs = {name: defs[name] for name in sorted(collected)}

    # Trim server-only fields from the root so authors aren't tempted to set them locally.
    root_copy = json.loads(json.dumps(out_defs[ROOT_DEFINITION]))
    for prop in READ_ONLY_PROPS_TO_DROP:
        root_copy.get("properties", {}).pop(prop, None)
    root_copy["required"] = [r for r in root_copy.get("required", []) if r not in READ_ONLY_PROPS_TO_DROP]
    out_defs[ROOT_DEFINITION] = root_copy

    schema = {
        "$schema": "http://json-schema.org/draft-04/schema#",
        "title": "ContentAnalyzer (local authoring schema)",
        "description": (
            "Schema for locally-authored Content Understanding analyzer definitions "
            "(the PUT /analyzers/{analyzerId} request body). Extracted from the official "
            "Azure REST API spec for api-version 2025-11-01 (GA). "
            "Source: https://github.com/Azure/azure-rest-api-specs/blob/main/specification/ai/"
            "data-plane/ContentUnderstanding/stable/2025-11-01/ContentUnderstanding.json"
        ),
        "$ref": f"#/definitions/{ROOT_DEFINITION}",
        "definitions": out_defs,
    }

    with open(OUTPUT_PATH, "w", encoding="utf-8") as f:
        json.dump(schema, f, indent=2)

    print(f"Wrote {OUTPUT_PATH} with {len(out_defs)} definitions: {', '.join(sorted(collected))}")


if __name__ == "__main__":
    main()
