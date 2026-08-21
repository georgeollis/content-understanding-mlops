# content-understand

A version-controlled, MLOps-oriented workflow for Microsoft Foundry Content Understanding
analyzers.

## Start here

- **[`docs/mlops-pipeline.md`](docs/mlops-pipeline.md)** — how this repo's author → promote →
  evaluate → record pipeline works, with a full diagram.
- **[`docs/azure-foundry-architecture.md`](docs/azure-foundry-architecture.md)** — the Microsoft
  Foundry infrastructure these analyzers are deployed against, with a full diagram.
- **[`analyzers/README.md`](analyzers/README.md)** — index of every analyzer family (what it
  extracts, what's currently deployed, golden test coverage).
- **[`schemas/README.md`](schemas/README.md)** — how `analyzer.json` files are validated and
  where the schema comes from.

## Pipeline: author → promote → evaluate → record

`analyzer.json` is edited and committed like normal source code (git = version history).
Promotion deploys its current contents to Microsoft Foundry under a new immutable `analyzerId`,
tags the commit in git, and updates a per-family `manifest.json` pointing at what's currently
live. Evaluation runs the golden test set through one or more live versions and diffs the
results; every comparison is saved as a git-tracked JSON report so accuracy is trackable over
time. Full details: [`docs/mlops-pipeline.md`](docs/mlops-pipeline.md).

```mermaid
graph TB
    subgraph AUTHOR["1. Author"]
        EDIT["Edit analyzer.json"] --> VALA["validate-analyzers.py<br/>+ validate-golden.py"]
        VALA --> CI["ci-check.ps1"] --> COMMIT["git commit"]
    end

    subgraph PROMOTE["2. Promote"]
        PROMOTESCRIPT["promote-analyzer.ps1"] --> UPLOAD["upload-analyzers.ps1<br/>PUT /analyzers/&lt;family&gt;v&lt;N&gt;"]
        UPLOAD --> TAG["git tag &lt;family&gt;-v&lt;N&gt;"]
        TAG --> MANIFEST["update manifest.json<br/>(current = &lt;family&gt;v&lt;N&gt;)"]
        COMMIT --> PROMOTESCRIPT
    end

    subgraph FOUNDRY_G["Microsoft Foundry"]
        ANALYZERS["analyzerId: &lt;family&gt;v1, v2, ... vN"]
    end
    UPLOAD ==>|"Entra ID token auth"| ANALYZERS

    subgraph EVALUATE["3. Evaluate"]
        COMPARESCRIPT["compare-analyzers.ps1<br/>-AnalyzerIds v1,v2,..."] --> SCORE["score vs golden/*.expected.json"]
        MANIFEST -.-> COMPARESCRIPT
        ANALYZERS --> SCORE
    end

    subgraph RECORD["4. Record"]
        REPORT["results/&lt;timestamp&gt;.json<br/>(accuracy + git commit hash)"]
        SCORE --> REPORT --> COMMIT2["git commit results/*.json"]
    end

    COMMIT2 -.->|"informs next"| EDIT
```

## Microsoft Foundry infrastructure

Analyzers are deployed against a private ("bring your own network") Microsoft Foundry account,
inside a VNet with private endpoints. Only the Content Understanding API on the Foundry account
is used by this pipeline — other project-scaffolding resources (AI Search, Cosmos DB, Container
Registry) exist alongside it but aren't called by these scripts. Full inventory + diagram:
[`docs/azure-foundry-architecture.md`](docs/azure-foundry-architecture.md).

```mermaid
graph TB
    DEV["content-understand repo<br/>(Entra ID token auth)"] ==>|"HTTPS<br/>/contentunderstanding/analyzers/*"| FOUNDRY

    subgraph RG["Resource Group (private / BYO-VNet)"]
        subgraph VNET["Virtual Network"]
            PESUBNET["Private-endpoint subnet"]
        end

        FOUNDRY["Foundry account (S0)<br/>disableLocalAuth=true"]
        PROJECT["Foundry project"]

        subgraph MON["Observability"]
            LAW["Log Analytics"] --- APPI["App Insights"]
            AMPLS["Azure Monitor Private Link Scope"]
        end

        FOUNDRY --> PROJECT
        FOUNDRY -.->|"diagnostics"| LAW
        AMPLS -.-> APPI
        PESUBNET -.-> FOUNDRY
        PESUBNET -.-> AMPLS
    end
```

## Layout

```
analyzers/<family>/   # one folder per analyzer (definition, promotion log, test data, results)
schemas/              # JSON Schemas + validation/generation tooling
scripts/              # PowerShell tooling: upload, promote, compare, CI check
docs/                 # architecture + pipeline documentation
```

## Common commands

```powershell
# Validate everything before committing/promoting
pwsh -File .\scripts\ci-check.ps1

# Promote a family's analyzer.json to a new versioned Microsoft Foundry deployment
pwsh -File .\scripts\promote-analyzer.ps1 -Endpoint <endpoint> -Family <family> -Notes "..."

# Compare two live versions against the golden set (saves a git-tracked report)
pwsh -File .\scripts\compare-analyzers.ps1 -Endpoint <endpoint> -Family <family> -AnalyzerIds <idA>, <idB>
```

> **Note**: scripts require PowerShell 7+ (`pwsh`). Windows PowerShell 5.1 (`powershell.exe`)
> throws a null-reference error in `Invoke-WebRequest` with these scripts.
