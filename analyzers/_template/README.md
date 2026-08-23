# Analyzer family template

The recommended way to start a new family is to run
[`scripts/new-analyzer.ps1`](../../scripts/new-analyzer.ps1), which copies this folder and
fills in placeholders for you:

```powershell
pwsh -File ./scripts/new-analyzer.ps1 -Family <family> -Description "One-line description"
```

Full walkthrough: [`../../docs/getting-started.md`](../../docs/getting-started.md).

<details>
<summary>Manual copy (if you'd rather not use the script)</summary>

```powershell
Copy-Item -Recurse analyzers/_template analyzers/<family>
```

Then fill in every placeholder yourself:

## What to fill in

| File | Do this |
|---|---|
| `analyzer.json` | Already has `config.estimateFieldSourceAndConfidence: true` set (so `compare-analyzers.ps1` reports per-field confidence once promoted). Replace the rest with the JSON exported from Foundry Studio's **Download** action (or hand-write it against [`schemas/analyzer.schema.json`](../../schemas/analyzer.schema.json)). For an existing family, you can also keep iterating live in Studio (dev only) and pull updates with [`sync-analyzer-from-studio.ps1`](../../scripts/sync-analyzer-from-studio.ps1) instead of re-copying by hand. |
| `manifest.dev.json` | Replace `<family>` and the `description` placeholder (shown in `analyzers/README.md`'s family index); leave `promotions`/`current` as-is — `promote-analyzer.ps1` fills those in on first promotion. Copy it again as `manifest.<env>.json` for each additional environment. |
| `golden/` | Add at least one `<name>.pdf`. For `<name>.expected.json`: either hand-write it (fields matching `analyzer.json`'s `fieldSchema`), or promote first and use [`bootstrap-golden.ps1`](../../scripts/bootstrap-golden.ps1) to draft it from the deployed analyzer's own output, then review/correct it. Delete this folder's `.gitkeep`. |
| `sample-documents/` | Optional: broader pool of sample/synthetic documents for this family, delete `.gitkeep` if unused |
| `results/` | Leave empty — `compare-analyzers.ps1` writes reports here automatically; delete `.gitkeep` once the first report exists |

## After filling these in

```powershell
pwsh -File ./schemas/build-ground-truth-schema.ps1 -Family <family>
pwsh -File ./schemas/build-golden-manifest.ps1 -Family <family>
pwsh -File ./scripts/ci-check.ps1
git add analyzers/<family>
git commit -m "Add <family> analyzer"
pwsh -File ./scripts/promote-analyzer.ps1 -Environment dev -Family <family> -Notes "Initial deployment"
```

</details>
