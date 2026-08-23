# Getting Started

Step-by-step path from a clean checkout to a promoted, evaluated analyzer.

---

## 1. Prerequisites

| Requirement | Why | Verify |
|---|---|---|
| PowerShell 7+ (`pwsh`) | All scripts use `Invoke-RestMethod`/`Invoke-WebRequest` features that throw under Windows PowerShell 5.1 | `pwsh -v` |
| Azure CLI (`az`), logged in | Scripts get an Entra ID token via `az account get-access-token` | `az account show` |
| RBAC on the target Foundry account | Data-plane calls need `Microsoft.CognitiveServices/accounts/*` access | `Cognitive Services User` role (or equivalent) assigned on the account |
| A Microsoft Foundry account with Content Understanding enabled and local authentication disabled | This is the deployment target; see [`azure-foundry-architecture.md`](azure-foundry-architecture.md) | Confirm the account's endpoint and your access |
| `azcopy` on `PATH` (only if using labeled training data) | Required by `copy-labeled-data.ps1` | `azcopy --version` |

Log in once per session:
```powershell
az login
az account set --subscription <subscription-id>
```

---

## 2. Configure `environments.json`

Clone the repo, then point at least one environment at a real Foundry account:

```json
{
  "environments": {
    "dev": {
      "endpoint": "https://<your-dev-resource>.cognitiveservices.azure.com",
      "labeledDataContainerUrl": "https://<your-dev-storage>.blob.core.windows.net/<container>"
    }
  }
}
```

`labeledDataContainerUrl` is only needed if an analyzer references
`knowledgeSources[].kind == "labeledData"` — omit it otherwise. This file is not meant to
contain secrets (no keys are stored here; auth is token-based — see
[`azure-foundry-architecture.md`](azure-foundry-architecture.md#authentication)).

If one analyzer family needs a different labeled-data container than others, add
`analyzers/<family>/environments.json` and override only the fields that differ (typically
`labeledDataContainerUrl`).

---

## 3. Author a new analyzer family

**Fast path** — one command scaffolds, optionally pulls from Studio, refreshes golden-set
artifacts, and validates:

```powershell
pwsh -File ./scripts/onboard-analyzer.ps1 -Family <family> -Description "One-line description" [-AnalyzerId <studio-analyzer-id>]
```

Omit `-AnalyzerId` if you're authoring `analyzer.json` by hand instead of pulling from Studio.
Safe to re-run as you iterate. See the printed "Next steps" for what's left (adding golden
docs, committing, promoting). The rest of this section explains what that wrapper does, if you
want to run the steps individually instead.

Scaffold the folder (copies `analyzers/_template`, fills in placeholders):

```powershell
pwsh -File ./scripts/new-analyzer.ps1 -Family <family> -Description "One-line description of what this analyzer extracts"
```

This creates `analyzers/<family>/` with `analyzer.json`, `manifest.dev.json`, and empty
`golden/`/`sample-documents/`/`results/` folders, and prints the exact next-step commands. Two
ways to produce the real `fieldSchema` inside `analyzer.json`:

- **Build it in Foundry Studio** (recommended for `dev`): design `fieldSchema` interactively,
  optionally attach labeled training data, then pull it down with
  `sync-analyzer-from-studio.ps1 -Environment dev -Family <family> -AnalyzerId <id>` (dev
  only — see step 7 below and
  [`mlops-pipeline.md`](mlops-pipeline.md#authoring-studio-dev-vs-this-repo-dev)). You can keep
  iterating live in Studio indefinitely and pull the current state down anytime.
- **Write it by hand**, matching [`schemas/analyzer.schema.json`](../schemas/analyzer.schema.json).
  VS Code shows inline validation/autocomplete for this automatically (see
  [`schemas/README.md`](../schemas/README.md#editor-validation-vs-code)).

For the golden set, add source documents (PDF, DOCX, XLSX, PPTX, images, and more — see
[`schemas/README.md`](../schemas/README.md) for the full supported list) plus hand-written
`<name>.expected.json` files (matching your `fieldSchema`), then generate the derived
schema/checksums in one step:

```powershell
pwsh -File ./schemas/update-golden.ps1 -Family <family>
```

(equivalent to running `build-ground-truth-schema.ps1` then `build-golden-manifest.ps1`
separately, if you want more granular control).

Hand-writing every `expected.json` field-by-field doesn't scale well. An alternative once
you've promoted a first version (step 5 below): use
[`bootstrap-golden.ps1`](../scripts/bootstrap-golden.ps1) to draft `expected.json` files from
the deployed analyzer's own output, then correct them — see
[`mlops-pipeline.md`](mlops-pipeline.md#bootstrapping-and-maintaining-the-golden-set).

---

## 4. Validate before committing

```powershell
pwsh -File ./scripts/ci-check.ps1
```

Runs analyzer-schema validation and golden-set integrity checks. If it reports a stale
checksum/schema (e.g. after editing a golden doc), auto-fix it and re-validate in one go:

```powershell
pwsh -File ./scripts/ci-check.ps1 -Fix
```

`-Fix` only regenerates derived artifacts (`expected.schema.json`, `manifest.json`) — anything
needing human judgment (an unreviewed `_bootstrap` marker, a genuinely missing field) still
fails and must be fixed by hand. Once it passes, commit:

```powershell
git add analyzers/<family>
git commit -m "Add <family> analyzer"
```

This same check re-runs automatically in GitHub Actions on every push/PR to `main`
([`.github/workflows/ci.yml`](../.github/workflows/ci.yml)) — running it locally first just
lets you catch and fix problems before pushing. See [Continuous
integration](mlops-pipeline.md#continuous-integration) for details.

---

## 5. First promotion (deploy to `dev`)

```powershell
pwsh -File ./scripts/promote-analyzer.ps1 -Environment dev -Family <family> -Notes "Initial deployment"
```

This deploys `analyzerId = "<family>v1"` and updates `manifest.dev.json`. Push your commit:

```powershell
git push origin main
```

If `analyzer.json` references labeled data and `dev`'s `labeledDataContainerUrl` doesn't yet
have the training blobs, copy them first (see
[`mlops-pipeline.md`](mlops-pipeline.md#labeled-data-across-environments)):

```powershell
pwsh -File ./scripts/copy-labeled-data.ps1 -Family <family> -SourceEnvironment <studio-source> -DestinationEnvironment dev -Prefix "labelingProjects/<id>/train"
```

---

## 6. First evaluation

Score the newly deployed analyzer against its own golden set:

```powershell
pwsh -File ./scripts/compare-analyzers.ps1 -Environment dev -Family <family> -AnalyzerIds <family>v1
```

Prints a per-document, per-field match table plus an aggregate accuracy percentage (and, since
`_template/analyzer.json` has `config.estimateFieldSourceAndConfidence: true` by default, an
average per-field confidence score too), and writes a report to `analyzers/<family>/results/`.
Commit the report:

```powershell
git add analyzers/<family>/results
git commit -m "Record <family>v1 evaluation"
git push origin main
```

---

## 7. Iterate

Two ways to iterate on an existing family, either can be committed and promoted the same way:

**Edit `analyzer.json` directly**: edit → `ci-check.ps1` → commit → `promote-analyzer.ps1` →
`compare-analyzers.ps1` (comparing the new version against the previous one, e.g.
`-AnalyzerIds <family>v1, <family>v2`) → commit results.

**Edit live in Studio (dev only)**: keep iterating in Studio against `dev` for as long as you
want, then pull the current state down when ready (or just re-run
`onboard-analyzer.ps1 -Family <family> -AnalyzerId <id>`, which does this plus the golden-set
refresh in one step):
```powershell
pwsh -File ./scripts/sync-analyzer-from-studio.ps1 -Environment dev -Family <family> -AnalyzerId <id>
```
This overwrites `analyzer.json` locally and never deploys anything itself — review the diff,
then continue with `ci-check.ps1` → commit → `promote-analyzer.ps1` as above. Restricted to
`dev`; `test`/`prod` are never edited in Studio.

Either way, see [`mlops-pipeline.md`](mlops-pipeline.md) for full stage-by-stage mechanics.

If the change added, renamed, or removed a `fieldSchema` field, sync the golden set before
`ci-check.ps1` will pass:
```powershell
pwsh -File ./schemas/build-ground-truth-schema.ps1 -Family <family>
pwsh -File ./schemas/sync-golden-fields.ps1 -Family <family>
# fill in any "<<FILL IN FROM SOURCE DOCUMENT>>" placeholders it adds, then:
pwsh -File ./schemas/build-golden-manifest.ps1 -Family <family>
```

## 8. Promoting to another environment (`test`, `prod`, ...)

Add the new environment to repo-root `environments.json` (and, if needed, family-specific
overrides to `analyzers/<family>/environments.json`), copy `manifest.dev.json` to
`manifest.<env>.json` (reset `current`/`promotions`), copy labeled data if applicable, then:

```powershell
pwsh -File ./scripts/promote-analyzer.ps1 -Environment <env> -Family <family> -Notes "Promote to <env>"
```

Studio is not used beyond `dev` — every other environment is reached exclusively through
`promote-analyzer.ps1`. See
[`mlops-pipeline.md`](mlops-pipeline.md#environments) for the full environment model.
