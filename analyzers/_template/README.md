# Analyzer family template

Copy this folder to `analyzers/<family>/` to start a new family, then fill in the placeholders.
Full walkthrough: [`../../docs/getting-started.md`](../../docs/getting-started.md).

```powershell
Copy-Item -Recurse analyzers\_template analyzers\<family>
```

## What to fill in

| File | Do this |
|---|---|
| `analyzer.json` | Replace with the JSON exported from Foundry Studio's **Download** action (or hand-write it against [`schemas/analyzer.schema.json`](../../schemas/analyzer.schema.json)) |
| `manifest.dev.json` | Leave as-is (`{ "current": null, "promotions": [] }`) — `promote-analyzer.ps1` fills this in on first promotion. Copy it again as `manifest.<env>.json` for each additional environment. |
| `golden/` | Add at least one `<name>.pdf` + hand-written `<name>.expected.json` pair (fields matching `analyzer.json`'s `fieldSchema`), then delete this folder's `.gitkeep` |
| `sample-documents/` | Optional: broader pool of sample/synthetic documents for this family, delete `.gitkeep` if unused |
| `results/` | Leave empty — `compare-analyzers.ps1` writes reports here automatically; delete `.gitkeep` once the first report exists |

## After filling these in

```powershell
pwsh -File .\schemas\build-ground-truth-schema.ps1 -Family <family>
pwsh -File .\schemas\build-golden-manifest.ps1 -Family <family>
pwsh -File .\scripts\ci-check.ps1
git add analyzers/<family>
git commit -m "Add <family> analyzer"
pwsh -File .\scripts\promote-analyzer.ps1 -Environment dev -Family <family> -Notes "Initial deployment"
```
