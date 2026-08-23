# Onboarding an analyzer built in Studio

Exact commands to take an analyzer you designed/iterated on in Foundry Studio (`dev`) and get
it fully into this repo, deployed as a tracked version, with a scored golden set, all committed
and pushed to GitHub. This is the "bring in what I built in dev" path — see
[`getting-started.md`](getting-started.md) for authoring a family from scratch instead.

Everything below assumes you're logged in (`az login` / `az account set --subscription <id>`)
and `environments.json` has a `dev` entry pointing at the Foundry account you built the
analyzer in.

---

## 1. Scaffold the family folder

```powershell
pwsh -File ./scripts/new-analyzer.ps1 -Family <family> -Description "One-line description of what this analyzer extracts"
```

- `<family>` must be lowercase letters/digits only, no hyphens (Content Understanding
  analyzerIds reject `-`, and `analyzerId` is derived as `<family>v<n>`).
- Creates `analyzers/<family>/analyzer.json` (placeholder `fieldSchema`),
  `manifest.dev.json`, and empty `golden/`, `sample-documents/`, `results/` folders.

## 2. Pull the real definition down from Studio

```powershell
pwsh -File ./scripts/sync-analyzer-from-studio.ps1 -Environment dev -Family <family> -AnalyzerId <studio-analyzer-id>
```

Overwrites `analyzer.json` locally with the live `fieldSchema` (and other config) from the
analyzer you built in Studio, stripping Studio/API-only metadata. Review the diff:

```powershell
git diff analyzers/<family>/analyzer.json
```

If `knowledgeSources[]` references a real storage container (e.g. `labeledData`), decide
whether to keep it as-is or generalize it before committing — it will be visible in git
history either way.

## 3. Add golden test documents

Add a handful of representative source documents (PDF, image, Office, or any other
[supported Content Understanding format](azure-foundry-architecture.md)) to
`analyzers/<family>/golden/`. Two ways to get `expected.json` ground truth for each:

**Hand-write it** (matches your `fieldSchema` exactly):
```powershell
pwsh -File ./schemas/build-ground-truth-schema.ps1 -Family <family>
```
writes `golden/expected.schema.json` so you know the exact shape to match per document.

**Or bootstrap it from the analyzer's own output** (faster, needs review after) — requires the
analyzer to already be promoted (step 4 below), then:
```powershell
pwsh -File ./scripts/bootstrap-golden.ps1 -Environment dev -Family <family> -AnalyzerId <family>v1
```
Drafts `<name>.expected.json` per document with a `_bootstrap` marker key. **Review every
value against the source document**, correct anything wrong, then delete the `_bootstrap` key
once verified.

Either way, once `golden/` is populated:
```powershell
pwsh -File ./schemas/build-golden-manifest.ps1 -Family <family>
```
Writes `golden/manifest.json` (checksums). If you hand-verified the bootstrapped values, also
set `"groundTruthSource": "human-verified"` per document in that file.

## 4. Validate

```powershell
pwsh -File ./scripts/ci-check.ps1
```

Checks analyzer-schema validity and golden-set integrity (checksums + no leftover `_bootstrap`
markers... actually `_bootstrap` isn't blocked by ci-check, review manually). Fix anything
reported, re-run until it passes.

## 5. Commit

```powershell
git add analyzers/<family>
git commit -m "Add <family> analyzer"
```

## 6. Promote (deploy the tracked version to `dev`)

```powershell
pwsh -File ./scripts/promote-analyzer.ps1 -Environment dev -Family <family> -Notes "Imported from Studio"
```

Deploys as `analyzerId = "<family>v1"` and updates `manifest.dev.json`.

## 7. Evaluate

```powershell
pwsh -File ./scripts/compare-analyzers.ps1 -Environment dev -Family <family> -AnalyzerIds <family>v1
```

Scores the promoted analyzer against the golden set, writes a report to
`analyzers/<family>/results/`.

## 8. Push everything

```powershell
git add analyzers/<family>/manifest.dev.json analyzers/<family>/results
git commit -m "Promote and evaluate <family>v1"
git push origin main
```

---

At this point: `analyzer.json` is git-tracked and matches what's deployed to `dev`, the golden
set is checksummed and (ideally) human-verified, `manifest.dev.json` records the deployment,
and a scored accuracy report is committed. To later promote the same version to another
environment, see
[`getting-started.md` §8](getting-started.md#8-promoting-to-another-environment-test-prod-).
