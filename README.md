# ContentUnderstandingOps

Version-controlled deployment pipeline for Azure AI Content Understanding analyzers. Analyzer
definitions are stored as JSON in this repository; `scripts/*.ps1` deploy them to Microsoft
Foundry resources via the Content Understanding REST API and record every deployment as a git
tag + manifest entry.

**Source of truth model:** `analyzer.json` (per family, per repo) is authoritative. Each
Foundry account (`environments.json` entry) is a deployment target, not a source. State is
reconciled one direction only: git → Azure, via `promote-analyzer.ps1`.

---

## Authoring model: Studio (dev) vs. this repo (dev+)

| | Foundry Studio | This repo |
|---|---|---|
| Scope | `dev` environment only | All environments, including `dev` after initial authoring |
| Persistence | Azure-side analyzer state only; no diff/history | Full git history per commit |
| Repeatable evaluation | None | `compare-analyzers.ps1` against a fixed golden set |
| Output artifact | Analyzer JSON (via Studio's "Download" action) | Same JSON, committed as `analyzers/<family>/analyzer.json` |

Studio is the recommended tool for interactively designing `fieldSchema` and building labeled
training sets (`knowledgeSources[].kind == "labeledData"`) against the `dev` Foundry account.
Once an analyzer is validated in Studio:

1. Use Studio's **Download** action on the built analyzer to export its JSON definition.
2. Commit that JSON as `analyzers/<family>/analyzer.json` (see
   [`schemas/analyzer.schema.json`](schemas/analyzer.schema.json) for the required shape).
3. From that commit forward, `dev` (re-promotions), `test`, `prod`, etc. are all deployed
   exclusively via `promote-analyzer.ps1`. Studio is not used again for that analyzer — editing
   it live in Studio would desynchronize the Azure-side analyzer from the git-tracked
   `analyzer.json`, with no mechanism to detect or reconcile the drift.

If the analyzer references labeled training data, see
[Labeled data across environments](docs/mlops-pipeline.md#labeled-data-across-environments) —
the data itself (blob storage) has to be copied per environment; `analyzer.json` alone doesn't
carry it.

---

## Reference documentation

| Doc | Scope |
|---|---|
| [`docs/getting-started.md`](docs/getting-started.md) | Step-by-step: prerequisites, first analyzer, first promotion, first evaluation |
| [`docs/mlops-pipeline.md`](docs/mlops-pipeline.md) | Pipeline stages, versioning model, environment promotion, labeled-data handling |
| [`docs/azure-foundry-architecture.md`](docs/azure-foundry-architecture.md) | REST operations used, auth flow, Azure resource scope |
| [`analyzers/README.md`](analyzers/README.md) | Per-family folder layout and generated index |
| [`schemas/README.md`](schemas/README.md) | `analyzer.json` / golden-set schema validation |

---

## Pipeline stages

```mermaid
graph LR
    A["1. Author<br/>analyzer.json"] --> B["2. Promote<br/>PUT /analyzers/{id}"]
    B --> C["3. Evaluate<br/>POST /analyzers/{id}:analyzeBinary"]
    C --> D["4. Record<br/>results/*.json committed"]
    D -.->|"repeat"| A
```

| Stage | Operation | Script |
|---|---|---|
| 1. Author | Edit `analyzer.json`; validated against `schemas/analyzer.schema.json` | *(edit + `ci-check.ps1` + commit)* |
| 2. Promote | Deploys as a new immutable `analyzerId` in one target environment; tags the commit | `promote-analyzer.ps1` |
| 3. Evaluate | Runs the golden PDF set through one or more live `analyzerId`s via `analyzeBinary`; scores field-level accuracy | `compare-analyzers.ps1` |
| 4. Record | Persists the scored comparison as JSON under `analyzers/<family>/results/` | *(automatic, part of stage 3)* |

Full mechanics: [`docs/mlops-pipeline.md`](docs/mlops-pipeline.md).

<details>
<summary>Detailed data-flow diagram</summary>

```mermaid
graph TB
    subgraph AUTHOR["1. Author"]
        EDIT["analyzer.json"] --> VALA["validate-analyzers.ps1"]
        VALA --> CI["ci-check.ps1"] --> COMMIT["git commit"]
    end

    subgraph PROMOTE["2. Promote"]
        PROMOTESCRIPT["promote-analyzer.ps1<br/>-Environment &lt;env&gt;"] --> UPLOAD["PUT /analyzers/{id}<br/>(upload-analyzers.ps1)"]
        UPLOAD --> TAG["git tag &lt;family&gt;-&lt;env&gt;-v&lt;N&gt;"]
        TAG --> MANIFEST["manifest.&lt;env&gt;.json"]
        COMMIT --> PROMOTESCRIPT
    end

    subgraph FOUNDRY_G["Microsoft Foundry (per environment)"]
        ANALYZERS["Deployed analyzerIds<br/>(immutable, never overwritten)"]
    end
    UPLOAD ==> ANALYZERS

    subgraph EVALUATE["3. Evaluate"]
        COMPARESCRIPT["compare-analyzers.ps1"] --> SCORE["Field-level match vs. golden set"]
        MANIFEST -.-> COMPARESCRIPT
        ANALYZERS --> SCORE
    end

    subgraph RECORD["4. Record"]
        REPORT["results/&lt;ts&gt;_&lt;env&gt;_&lt;ids&gt;.json"]
        SCORE --> REPORT --> COMMIT2["git commit"]
    end

    COMMIT2 -.->|"informs next iteration"| EDIT
```

</details>

---

## Azure surface area

Only the Content Understanding data-plane API is used: `PUT /analyzers/{id}` (create) and
`POST /analyzers/{id}:analyzeBinary` (extract). Auth is Microsoft Entra ID token-based
(`disableLocalAuth: true`; no subscription keys). Full detail:
[`docs/azure-foundry-architecture.md`](docs/azure-foundry-architecture.md).

```mermaid
graph LR
    REPO["scripts/*.ps1"] -->|"Bearer token (Entra ID)"| FOUNDRY["Foundry account<br/>Content Understanding API"]
```

---

## Environments

Each named environment in [`environments.json`](environments.json) maps to a distinct Foundry
account (`endpoint`) and, optionally, a distinct labeled-data blob container
(`labeledDataContainerUrl`). Environments do not share deployed `analyzerId`s, manifests, or
labeled data — each is independently promoted to.

A git branch merge changes tracked files only; it never invokes the Azure API. Promoting to an
environment is always an explicit, separate step:

```powershell
pwsh -File .\scripts\promote-analyzer.ps1 -Environment dev  -Family invoice -Notes "..."
pwsh -File .\scripts\promote-analyzer.ps1 -Environment test -Family invoice -Notes "..."
```

Beyond `dev`, promotion is the only supported path to any environment — there is no Studio
equivalent for `test`/`prod`/etc.

---

## Repository layout

| Path | Contents |
|---|---|
| `analyzers/<family>/` | `analyzer.json`, per-environment `manifest.<env>.json`, `golden/` test set, `results/` |
| `schemas/` | JSON Schemas + validation/generation scripts |
| `scripts/` | `promote-analyzer.ps1`, `compare-analyzers.ps1`, `upload-analyzers.ps1`, `copy-labeled-data.ps1`, `ci-check.ps1` |
| `docs/` | Reference documentation |
| `environments.json` | Environment name → `{ endpoint, labeledDataContainerUrl }` |

---

## Command reference

```powershell
# Run all validation checks (schema, golden-set integrity, family index freshness)
pwsh -File .\scripts\ci-check.ps1

# Deploy analyzer.json as a new analyzerId in one environment; tags the commit; updates manifest.<env>.json
pwsh -File .\scripts\promote-analyzer.ps1 -Environment dev -Family <family> -Notes "..."

# Run the golden PDF set through one or more analyzerIds; prints + saves per-field accuracy
pwsh -File .\scripts\compare-analyzers.ps1 -Environment dev -Family <family> -AnalyzerIds <idA>, <idB>

# Copy labeled-data blobs from one environment's storage container to another's (same prefix)
pwsh -File .\scripts\copy-labeled-data.ps1 -SourceEnvironment dev -DestinationEnvironment test -Prefix "labelingProjects/<id>/train"
```

> Requires PowerShell 7+ (`pwsh`). `Invoke-WebRequest` throws under Windows PowerShell 5.1.
