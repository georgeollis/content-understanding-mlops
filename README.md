# ContentUnderstandingOps

A simple, version-controlled way to manage Microsoft Foundry Content Understanding analyzers.

Think of it like this: **git is where analyzers are designed and tested. Azure is where they run.**

---

## 🎯 The one rule to remember

| | Use for | Treat as |
|---|---|---|
| **Foundry Studio** | Quick dev/POC experiments | Throwaway — never "the real thing" |
| **This repo** | Anything real | The source of truth |

Once an idea works in Studio, copy it into `analyzer.json`, commit it, and deploy it with a
script. After that, **only this repo should touch that analyzer** — not Studio.

**Why?** Studio has no version history and no tests. If someone edits a live analyzer in
Studio, git and Azure quietly go out of sync — and nobody would notice.

---

## 📖 Read next

| Doc | What it covers |
|---|---|
| [`docs/mlops-pipeline.md`](docs/mlops-pipeline.md) | How the 4-step pipeline works |
| [`docs/azure-foundry-architecture.md`](docs/azure-foundry-architecture.md) | The Azure setup analyzers run on |
| [`analyzers/README.md`](analyzers/README.md) | List of analyzers and their status |
| [`schemas/README.md`](schemas/README.md) | How `analyzer.json` gets validated |

---

## 🔄 The 4-step pipeline

```mermaid
graph LR
    A["1️⃣ Author<br/>edit analyzer.json"] --> B["2️⃣ Promote<br/>deploy to Foundry"]
    B --> C["3️⃣ Evaluate<br/>score vs. test docs"]
    C --> D["4️⃣ Record<br/>save results to git"]
    D -.->|"repeat"| A
```

| Step | What happens | Command |
|---|---|---|
| 1️⃣ **Author** | Edit `analyzer.json` like normal code | *(just edit + commit)* |
| 2️⃣ **Promote** | Deploy it to Foundry as a new version | `promote-analyzer.ps1` |
| 3️⃣ **Evaluate** | Test it against known-correct answers | `compare-analyzers.ps1` |
| 4️⃣ **Record** | Save the score as a file in git | *(done automatically)* |

Full details: [`docs/mlops-pipeline.md`](docs/mlops-pipeline.md).

<details>
<summary>Show detailed pipeline diagram</summary>

```mermaid
graph TB
    subgraph AUTHOR["1. Author"]
        EDIT["Edit analyzer.json"] --> VALA["Validate"]
        VALA --> CI["ci-check.ps1"] --> COMMIT["git commit"]
    end

    subgraph PROMOTE["2. Promote"]
        PROMOTESCRIPT["promote-analyzer.ps1"] --> UPLOAD["Deploy to Foundry"]
        UPLOAD --> TAG["git tag"]
        TAG --> MANIFEST["update manifest.json"]
        COMMIT --> PROMOTESCRIPT
    end

    subgraph FOUNDRY_G["Microsoft Foundry"]
        ANALYZERS["Live analyzer versions"]
    end
    UPLOAD ==> ANALYZERS

    subgraph EVALUATE["3. Evaluate"]
        COMPARESCRIPT["compare-analyzers.ps1"] --> SCORE["Score vs. test data"]
        MANIFEST -.-> COMPARESCRIPT
        ANALYZERS --> SCORE
    end

    subgraph RECORD["4. Record"]
        REPORT["Save results as JSON"]
        SCORE --> REPORT --> COMMIT2["git commit"]
    end

    COMMIT2 -.->|"informs next"| EDIT
```

</details>

---

## ☁️ The Azure setup (short version)

Analyzers run on a private Microsoft Foundry account. Only the Content Understanding API is
used by this pipeline — nothing else needs to be touched.

```mermaid
graph LR
    REPO["This repo"] -->|"deploy / test"| FOUNDRY["Microsoft Foundry<br/>(private network)"]
```

Full inventory + diagram: [`docs/azure-foundry-architecture.md`](docs/azure-foundry-architecture.md).

---

## 📁 Folder guide

| Folder | Contains |
|---|---|
| `analyzers/<family>/` | One analyzer's definition, deployment history, test data, results |
| `schemas/` | Validation rules + tooling |
| `scripts/` | The PowerShell tools: upload, promote, compare, CI check |
| `docs/` | This documentation |

---

## ⚡ Quick commands

```powershell
# ✅ Check everything is valid before committing
pwsh -File .\scripts\ci-check.ps1

# 🚀 Deploy an analyzer.json as a new version
pwsh -File .\scripts\promote-analyzer.ps1 -Endpoint <endpoint> -Family <family> -Notes "..."

# 📊 Compare two versions against test documents
pwsh -File .\scripts\compare-analyzers.ps1 -Endpoint <endpoint> -Family <family> -AnalyzerIds <idA>, <idB>
```

> ⚠️ **Requires PowerShell 7 (`pwsh`), not Windows PowerShell 5.1** — the older version errors
> out on these scripts.
