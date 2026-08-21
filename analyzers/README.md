# Analyzer Families

Each subfolder here is a self-contained analyzer family: its versioned definition, deployment
history, and test data all live together so it's obvious what documents/forms an analyzer relates
to. See `../schemas/README.md` for schema validation and `../scripts/` for the tooling that
operates on these folders.

## Layout convention (per family)

```
analyzers/<family>/
  analyzer.json       # single mutable source of truth (git-tracked; history via commits/tags)
  manifest.json        # promotion log: which git tag/commit is deployed as which Azure analyzerId
  sample-documents/    # broader pool of sample/synthetic documents for this document type
  golden/
    *.pdf + *.expected.json   # curated subset used for accuracy scoring
    expected.schema.json       # derived from analyzer.json fieldSchema (schemas/build-ground-truth-schema.py)
    manifest.json               # checksummed index of the golden set (schemas/build-golden-manifest.py)
```

## Index

<!-- Regenerate this table with: python schemas/list-families.py -->

| Family | Description | Current (live) | Golden docs |
|---|---|---|---|
| `complaint` | Extracts structured fields from customer complaint forms (customer contact details, complaint nature, incident details, desired resolution). | `_(not deployed)_` | 5 |
| `invoice` | Extracts invoice header, business (from) and client (for) contact details. | `invoicev2` | 5 |

## Common commands

```powershell
# Validate everything before committing/promoting
.\scripts\ci-check.ps1

# Promote a family's analyzer.json to a new versioned Azure deployment
.\scripts\promote-analyzer.ps1 -Endpoint <endpoint> -Family <family> -Notes "..."

# Compare two live versions (or a candidate vs. current) against the golden set
.\scripts\compare-analyzers.ps1 -Endpoint <endpoint> -Family <family> -AnalyzerIds <idA>, <idB>
```
