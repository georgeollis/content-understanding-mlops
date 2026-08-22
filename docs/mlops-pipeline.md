# MLOps Pipeline

How this repo takes an analyzer from an idea to a tested, deployed version — and keeps a
history of everything.

---

## 🎯 Studio vs. this repo

| | Foundry Studio | This repo |
|---|---|---|
| Good for | Quick experiments | Anything real |
| Has version history? | ❌ No | ✅ Yes (git) |
| Has repeatable tests? | ❌ No | ✅ Yes (golden test set) |
| Should you trust it long-term? | ❌ No | ✅ Yes |

**Rule of thumb:** prototype in Studio → once it works, copy it into `analyzer.json` → from
then on, only this repo's scripts should touch that analyzer.

---

## 🔄 The 4 stages

```mermaid
graph LR
    A["1️⃣ Author"] --> B["2️⃣ Promote"]
    B --> C["3️⃣ Evaluate"]
    C --> D["4️⃣ Record"]
    D -.-> A
```

### 1️⃣ Author
Edit `analyzer.json` and its test data, just like any code change.
- ✅ Checked automatically by `ci-check.ps1`
- 📍 Lives in `analyzers/<family>/analyzer.json`

### 2️⃣ Promote
Deploy the current `analyzer.json` to Microsoft Foundry as a **new, permanent version**
**in one environment**.
- 🚀 Run with: `promote-analyzer.ps1 -Environment dev -Family <family>`
- Creates a new `analyzerId` (e.g. `invoicev3`) — old versions are never overwritten
- Tags the git commit and updates that environment's `manifest.<env>.json` (so you always know
  what's live in each environment)
- ⚠️ Only deploys to the environment you pass — promoting to `dev` never touches `test`/`prod`

### 3️⃣ Evaluate
Run the test documents through one or more live versions and score the results.
- 📊 Run with: `compare-analyzers.ps1 -Environment dev -Family <family> -AnalyzerIds v1,v2`
- Compares extracted fields against known-correct answers
- Great for checking a new version didn't break anything

### 4️⃣ Record
Every comparison is saved as a JSON file and committed to git.
- 📁 Saved to `analyzers/<family>/results/`
- Lets you track accuracy over time just by looking at git history

---

## 🌍 Multiple environments (dev/test/prod)

Each environment is its own Foundry account, with its own endpoint (listed in
[`environments.json`](../environments.json)) and its own `manifest.<env>.json` per family.

**The key thing to remember:** a git branch merge (e.g. `dev` → `test`) only moves the
`analyzer.json` file — it does **not** create the analyzer in the target environment's Azure
account. Promotion is a separate, explicit step that must be re-run per environment:

```mermaid
graph LR
    subgraph GIT["Git branches"]
        DEVBR["dev branch"] -->|"merge (approved)"| TESTBR["test branch"]
        TESTBR -->|"merge (approved)"| MAINBR["main branch"]
    end
    subgraph DEPLOY["Still required after each merge"]
        P1["promote-analyzer.ps1<br/>-Environment dev"]
        P2["promote-analyzer.ps1<br/>-Environment test"]
        P3["promote-analyzer.ps1<br/>-Environment prod"]
    end
    DEVBR -.-> P1
    TESTBR -.-> P2
    MAINBR -.-> P3
    P1 --> FDEV["Foundry (dev)"]
    P2 --> FTEST["Foundry (test)"]
    P3 --> FPROD["Foundry (prod)"]
```

If you try to run/compare an analyzer in an environment before promoting it there, the request
will fail (the `analyzerId` doesn't exist yet) — that failure is a useful signal that a
promotion step was missed, not a bug.

---

## 🧰 What's in the toolbox

| Tool | What it does |
|---|---|
| `promote-analyzer.ps1` | Deploys `analyzer.json` as a new version, in one environment |
| `compare-analyzers.ps1` | Scores one or more versions against test documents, in one environment |
| `upload-analyzers.ps1` | Low-level deploy step (used internally by promote) |
| `ci-check.ps1` | Runs all validation checks in one command |
| `validate-analyzers.ps1` | Checks `analyzer.json` is valid |
| `validate-golden.ps1` | Checks the test data is valid and matches the schema |

| File | What it's for |
|---|---|
| `analyzers/<family>/analyzer.json` | The analyzer definition (the thing you edit) |
| `analyzers/<family>/manifest.<env>.json` | Which version is currently live, per environment |
| `analyzers/<family>/golden/` | Test documents + correct answers |
| `analyzers/<family>/results/` | Saved accuracy reports (per environment) |
| `environments.json` | Environment name → Foundry endpoint mapping |

---

## 🔍 How versioning works

- `analyzer.json` is **edited like normal code** — git tracks its full history.
- Azure doesn't understand "versions" — each promotion just creates a brand-new,
  permanent `analyzerId` (like `invoicev1`, `invoicev2`, ...). Old ones are never deleted.
- `manifest.json` always says which one is `current`. It's auto-generated — never edit it
  by hand.

## 🔍 How the quality check works

`compare-analyzers.ps1` runs the same test documents through two (or more) versions and shows
a side-by-side score. Because every result is saved to git, you can see accuracy trends over
time with a normal `git log`.

---

<details>
<summary>Show full technical diagram</summary>

```mermaid
graph TB
    subgraph AUTHOR["1. Author (local, git-tracked)"]
        EDIT["Edit analyzers/&lt;family&gt;/analyzer.json"]
        VALA["validate-analyzers.ps1"]
        GTSCHEMA["build-ground-truth-schema.ps1"]
        GOLDMAN["build-golden-manifest.ps1"]
        VALG["validate-golden.ps1"]
        CI["ci-check.ps1"]
        COMMIT["git commit"]

        EDIT --> VALA
        EDIT --> GTSCHEMA --> VALG
        GTSCHEMA --> GOLDMAN --> VALG
        VALA --> CI
        VALG --> CI
        CI --> COMMIT
    end

    subgraph PROMOTE["2. Promote (per environment)"]
        PROMOTESCRIPT["promote-analyzer.ps1 -Environment &lt;env&gt;"]
        UPLOAD["upload-analyzers.ps1<br/>deploy new analyzerId"]
        TAG["git tag"]
        MANIFEST["update manifest.&lt;env&gt;.json"]

        COMMIT --> PROMOTESCRIPT
        PROMOTESCRIPT --> UPLOAD --> TAG --> MANIFEST
    end

    subgraph AZURE["Microsoft Foundry"]
        ANALYZERV1["analyzerId: v1"]
        ANALYZERV2["analyzerId: v2"]
        ANALYZERVN["analyzerId: vN"]
    end

    UPLOAD ==> ANALYZERV1
    UPLOAD ==> ANALYZERV2
    UPLOAD ==> ANALYZERVN

    subgraph EVALUATE["3. Evaluate"]
        COMPARESCRIPT["compare-analyzers.ps1"]
        SCORE["Score vs. test answers"]

        MANIFEST -.-> COMPARESCRIPT
        COMPARESCRIPT --> ANALYZERV1
        COMPARESCRIPT --> ANALYZERV2
        ANALYZERV1 --> SCORE
        ANALYZERV2 --> SCORE
    end

    subgraph RECORD["4. Record"]
        REPORT["results/&lt;timestamp&gt;.json"]
        COMMIT2["git commit"]

        SCORE --> REPORT --> COMMIT2
    end

    COMMIT2 -.->|"informs next"| EDIT
```

</details>

---

## 💡 Ideas for later (not built yet — this is a lab)

- **Block bad promotions** — stop `promote-analyzer.ps1` if accuracy drops vs. the current version
- **Automate the checks** — run `ci-check.ps1` automatically on every pull request
- **Auto-promote on merge** — trigger `promote-analyzer.ps1 -Environment <env>` automatically
  in CI when a branch merges to that environment's branch, instead of relying on someone to
  remember to run it manually
- **Drift detection** — catch it automatically if someone edits an analyzer in Studio instead
  of through this pipeline
