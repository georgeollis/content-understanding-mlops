# Getting Started

Step-by-step path from a clean checkout to a promoted, evaluated analyzer.

---

## 1. Prerequisites

| Requirement | Why | Verify |
|---|---|---|
| PowerShell 7+ (`pwsh`) | All scripts use `Invoke-RestMethod`/`Invoke-WebRequest` features that throw under Windows PowerShell 5.1 | `pwsh -v` |
| Azure CLI (`az`), logged in | Scripts get an Entra ID token via `az account get-access-token` | `az account show` |
| RBAC on the target Foundry account | Data-plane calls need `Microsoft.CognitiveServices/accounts/*` access | `Cognitive Services User` role (or equivalent) assigned on the account |
| A Foundry account (`AIServices`/Foundry kind) with `disableLocalAuth: true` | This is the deployment target; see [`azure-foundry-architecture.md`](azure-foundry-architecture.md) | `az cognitiveservices account show -n <name> -g <rg>` |
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

---

## 3. Author a new analyzer family

Scaffold the folder (copies `analyzers/_template`, fills in placeholders):

```powershell
pwsh -File .\scripts\new-analyzer.ps1 -Family <family> -Description "One-line description of what this analyzer extracts"
```

This creates `analyzers/<family>/` with `analyzer.json`, `manifest.dev.json`, and empty
`golden/`/`sample-documents/`/`results/` folders, and prints the exact next-step commands. Two
ways to produce the real `fieldSchema` inside `analyzer.json`:

- **Build it in Foundry Studio** (recommended for `dev`): design `fieldSchema` interactively,
  optionally attach labeled training data, then export the JSON over the placeholder
  `fieldSchema` `new-analyzer.ps1` left in place. For an existing family, you can keep
  iterating live in Studio indefinitely and pull the current state down anytime with
  `sync-analyzer-from-studio.ps1` (dev only — see step 8 below and
  [`mlops-pipeline.md`](mlops-pipeline.md#authoring-studio-dev-vs-this-repo-dev)).
- **Write it by hand**, matching [`schemas/analyzer.schema.json`](../schemas/analyzer.schema.json).
  VS Code shows inline validation/autocomplete for this automatically (see
  [`schemas/README.md`](../schemas/README.md#editor-validation-vs-code)).

For the golden set, add PDFs plus hand-written `<name>.expected.json` files (matching your
`fieldSchema`), then generate the derived schema/checksums:

```powershell
pwsh -File .\schemas\build-ground-truth-schema.ps1 -Family <family>
pwsh -File .\schemas\build-golden-manifest.ps1 -Family <family>
```

Hand-writing every `expected.json` field-by-field doesn't scale well. An alternative once
you've promoted a first version (step 5 below): use
[`bootstrap-golden.ps1`](../scripts/bootstrap-golden.ps1) to draft `expected.json` files from
the deployed analyzer's own output, then correct them — see
[`mlops-pipeline.md`](mlops-pipeline.md#bootstrapping-and-maintaining-the-golden-set).

---

## 4. Validate before committing

```powershell
pwsh -File .\scripts\ci-check.ps1
```

Runs analyzer-schema validation, golden-set integrity checks, and regenerates
`analyzers/README.md`'s family index if stale. Fix any reported errors, then commit:

```powershell
git add analyzers/<family>
git commit -m "Add <family> analyzer"
```

---

## 5. First promotion (deploy to `dev`)

```powershell
pwsh -File .\scripts\promote-analyzer.ps1 -Environment dev -Family <family> -Notes "Initial deployment"
```

This requires a clean git working tree for `analyzer.json` (commit first). It deploys
`analyzerId = "<family>v1"`, creates git tag `<family>-dev-v1`, and updates
`manifest.dev.json`. Push the tag:

```powershell
git push origin main
git push origin <family>-dev-v1
```

If `analyzer.json` references labeled data and `dev`'s `labeledDataContainerUrl` doesn't yet
have the training blobs, copy them first (see
[`mlops-pipeline.md`](mlops-pipeline.md#labeled-data-across-environments)):

```powershell
pwsh -File .\scripts\copy-labeled-data.ps1 -SourceEnvironment <studio-source> -DestinationEnvironment dev -Prefix "labelingProjects/<id>/train"
```

---

## 6. First evaluation

Score the newly deployed analyzer against its own golden set:

```powershell
pwsh -File .\scripts\compare-analyzers.ps1 -Environment dev -Family <family> -AnalyzerIds <family>v1
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
want, then pull the current state down when ready:
```powershell
pwsh -File .\scripts\sync-analyzer-from-studio.ps1 -Environment dev -Family <family> -AnalyzerId <id>
```
This overwrites `analyzer.json` locally and never deploys anything itself — review the diff,
then continue with `ci-check.ps1` → commit → `promote-analyzer.ps1` as above. Restricted to
`dev`; `test`/`prod` are never edited in Studio.

Either way, see [`mlops-pipeline.md`](mlops-pipeline.md) for full stage-by-stage mechanics.

If the change added, renamed, or removed a `fieldSchema` field, sync the golden set before
`ci-check.ps1` will pass:
```powershell
pwsh -File .\schemas\build-ground-truth-schema.ps1 -Family <family>
pwsh -File .\schemas\sync-golden-fields.ps1 -Family <family>
# fill in any "<<FILL IN FROM PDF>>" placeholders it adds, then:
pwsh -File .\schemas\build-golden-manifest.ps1 -Family <family>
```

## 8. Promoting to another environment (`test`, `prod`, ...)

Add the new environment to `environments.json`, copy `manifest.dev.json` to
`manifest.<env>.json` (reset `current`/`promotions`), copy labeled data if applicable, then:

```powershell
pwsh -File .\scripts\promote-analyzer.ps1 -Environment <env> -Family <family> -Notes "Promote to <env>"
```

Studio is not used beyond `dev` — every other environment is reached exclusively through
`promote-analyzer.ps1`. See
[`mlops-pipeline.md`](mlops-pipeline.md#environments) for the full environment model.
