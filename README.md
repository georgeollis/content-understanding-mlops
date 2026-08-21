# content-understand

A version-controlled, MLOps-oriented workflow for Azure AI Content Understanding analyzers.

## Start here

- **[`docs/mlops-pipeline.md`](docs/mlops-pipeline.md)** — how this repo's author → promote →
  evaluate → record pipeline works, with a full diagram.
- **[`docs/azure-foundry-architecture.md`](docs/azure-foundry-architecture.md)** — the Azure AI
  Foundry infrastructure these analyzers are deployed against, with a full diagram.
- **[`analyzers/README.md`](analyzers/README.md)** — index of every analyzer family (what it
  extracts, what's currently deployed, golden test coverage).
- **[`schemas/README.md`](schemas/README.md)** — how `analyzer.json` files are validated and
  where the schema comes from.

## Pipeline: author → promote → evaluate → record

`analyzer.json` is edited and committed like normal source code (git = version history).
Promotion deploys its current contents to Azure under a new immutable `analyzerId`, tags the
commit in git, and updates a per-family `manifest.json` pointing at what's currently live.
Evaluation runs the golden test set through one or more live versions and diffs the results;
every comparison is saved as a git-tracked JSON report so accuracy is trackable over time.
Full details: [`docs/mlops-pipeline.md`](docs/mlops-pipeline.md).

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

    subgraph AZURE["Azure AI Foundry"]
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

## Azure infrastructure

Analyzers are deployed against a private ("bring your own network") Azure AI Foundry account
(`byofoundrylfgymnr5a` in `rg-foundry-byo-test`), with AI Search, Cosmos DB, Storage, and ACR all
behind private endpoints. Full inventory + diagram: [`docs/azure-foundry-architecture.md`](docs/azure-foundry-architecture.md).

```mermaid
graph TB
    DEV["content-understand repo<br/>(Entra ID token auth)"] ==>|"HTTPS<br/>/contentunderstanding/analyzers/*"| FOUNDRY

    subgraph RG["rg-foundry-byo-test (Sweden Central)"]
        subgraph VNET["agent-vnet-byotest (192.168.0.0/16)"]
            PESUBNET["pe-subnet: private endpoints for<br/>Foundry account, Search, Cosmos DB, Storage, ACR, AMPLS"]
        end

        FOUNDRY["byofoundrylfgymnr5a<br/>AI Foundry account (S0)<br/>disableLocalAuth=true"]
        PROJECT["byo-test-projectnr5a<br/>Foundry project"]
        SEARCH["AI Search (standard)<br/>publicNetworkAccess: Disabled"]
        COSMOS["Cosmos DB<br/>publicNetworkAccess: Disabled"]
        STORAGE["Storage (ZRS)<br/>publicNetworkAccess: Disabled"]
        ACR["Container Registry (Premium)<br/>publicNetworkAccess: Disabled"]

        subgraph MON["Observability"]
            LAW["Log Analytics"] --- APPI["App Insights"]
            AMPLS["Azure Monitor Private Link Scope"]
        end

        FOUNDRY --> PROJECT
        PROJECT -.->|"grounding/vector search"| SEARCH
        PROJECT -.->|"agent/thread state"| COSMOS
        PROJECT -.->|"blob storage"| STORAGE
        PROJECT -.->|"container images"| ACR
        FOUNDRY -.->|"diagnostics"| LAW
        AMPLS -.-> APPI
        PESUBNET -.-> FOUNDRY
        PESUBNET -.-> SEARCH
        PESUBNET -.-> COSMOS
        PESUBNET -.-> STORAGE
        PESUBNET -.-> ACR
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

# Promote a family's analyzer.json to a new versioned Azure deployment
pwsh -File .\scripts\promote-analyzer.ps1 -Endpoint <endpoint> -Family <family> -Notes "..."

# Compare two live versions against the golden set (saves a git-tracked report)
pwsh -File .\scripts\compare-analyzers.ps1 -Endpoint <endpoint> -Family <family> -AnalyzerIds <idA>, <idB>
```

> **Note**: scripts require PowerShell 7+ (`pwsh`). Windows PowerShell 5.1 (`powershell.exe`)
> throws a null-reference error in `Invoke-WebRequest` with these scripts.

