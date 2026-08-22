# Analyzer Families

Each subfolder here is a self-contained analyzer family: its versioned definition, deployment
history, and test data all live together so it's obvious what documents/forms an analyzer relates
to. See `../schemas/README.md` for schema validation and `../scripts/` for the tooling that
operates on these folders. See `../docs/mlops-pipeline.md` for a full diagram of this pipeline,
and `../docs/azure-foundry-architecture.md` for the underlying Azure infrastructure.

## Layout convention (per family)

```
analyzers/<family>/
  analyzer.json         # single mutable source of truth (git-tracked; history via commits/tags)
  manifest.<env>.json    # one per environment (dev/test/prod, ...) - which analyzerId is
                           # currently live IN THAT ENVIRONMENT'S Foundry account. Promoting to
                           # one environment never affects another's manifest or deployment.
  sample-documents/      # broader pool of sample/synthetic documents for this document type
  golden/
    *.pdf + *.expected.json   # curated subset used for accuracy scoring
    expected.schema.json       # derived from analyzer.json fieldSchema (schemas/build-ground-truth-schema.ps1)
    manifest.json               # checksummed index of the golden set (schemas/build-golden-manifest.ps1)
  results/
    <timestamp>_<environment>_<analyzerIds>.json   # git-tracked accuracy reports, per environment
```

See the repo root [`environments.json`](../environments.json) for the environment -> endpoint
mapping used by `-Environment` on the scripts below.

## Index

<!-- Regenerate this table with: pwsh -File schemas/list-families.ps1 -WriteReadme -->

| Family | Description | Current (by environment) | Golden docs |
|---|---|---|---|
| `complaint` | Extracts structured fields from customer complaint forms (customer contact details, complaint nature, incident details, desired resolution). | dev: `complaintv1` | 5 |
| `invoice` | Extracts invoice header, business (from) and client (for) contact details. | dev: `invoicev2` | 5 |

## Common commands

```powershell
# Validate everything before committing/promoting
.\scripts\ci-check.ps1

# Promote a family's analyzer.json to a new versioned deployment in one environment
.\scripts\promote-analyzer.ps1 -Environment dev -Family <family> -Notes "..."

# Compare two live versions (or a candidate vs. current) against the golden set, in one environment
# Saves a JSON report to analyzers/<family>/results/ by default (commit it to track accuracy over time)
.\scripts\compare-analyzers.ps1 -Environment dev -Family <family> -AnalyzerIds <idA>, <idB>
```

> ⚠️ **Promoting to one environment does not deploy to any other.** After merging a branch
> that changes `analyzer.json` into `test` or `main`, you still need to run
> `promote-analyzer.ps1 -Environment <that-environment>` to actually create the analyzer there
> — a git merge only changes the file, it never calls Azure.
