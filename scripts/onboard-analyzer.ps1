<#
.SYNOPSIS
  End-to-end wrapper: scaffold (if new), optionally pull from Studio, refresh derived golden
  artifacts, and validate a single analyzer family in one command.

.DESCRIPTION
  Combines the steps normally run one at a time when onboarding a family (see
  docs/getting-started.md):
    1. If analyzers/<Family> doesn't exist yet, runs new-analyzer.ps1 -Family -Description.
    2. If -AnalyzerId is supplied, runs sync-analyzer-from-studio.ps1 to pull the live
       definition down from Studio into analyzer.json (dev only, same restriction as that
       script). Skip this and edit analyzer.json by hand instead if you're not using Studio.
    3. Runs schemas/update-golden.ps1 -Family (refreshes expected.schema.json + manifest.json)
       - safe to run even before any golden docs are added.
    4. Runs validate-analyzers.ps1 and validate-golden.ps1 for just this family, and prints
       what's still needed (e.g. add golden docs, review bootstrapped ground truth) before
       you commit and promote.

  This script never calls promote-analyzer.ps1 or commits/pushes anything - deploying and
  committing remain explicit, separate steps you run yourself once you're happy with the diff.

.PARAMETER Family
  Analyzer family folder name, e.g. "invoice". Lowercase letters/digits only, no hyphens.

.PARAMETER Description
  One-line description of what this analyzer extracts (only used if scaffolding a new family).

.PARAMETER Environment
  Environment to pull from Studio, if -AnalyzerId is supplied. Defaults to "dev".

.PARAMETER AnalyzerId
  The analyzerId currently live in Studio to pull down. Omit if you're authoring analyzer.json
  by hand instead of via Studio.

.EXAMPLE
  # Brand-new family, authored by hand (no Studio pull)
  .\onboard-analyzer.ps1 -Family receipt -Description "Extracts merchant, line items, and totals"

.EXAMPLE
  # Bring in a family you built/iterated on in Foundry Studio
  .\onboard-analyzer.ps1 -Family businessinvoice -Description "Extracts business invoice fields" -AnalyzerId businessinvoicev3

.NOTES
  Full manual walkthrough (if you'd rather run each step yourself): docs/getting-started.md
#>
param(
  [Parameter(Mandatory = $true)]
  [string]$Family,

  [string]$Description,

  [string]$Environment = "dev",

  [string]$AnalyzerId
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$schemasDir = Join-Path $repoRoot "schemas"
$familyDir = Join-Path $repoRoot "analyzers" $Family

function Step {
  param([string]$Name)
  Write-Host ""
  Write-Host "==> $Name" -ForegroundColor Cyan
}

# ---------- 1. Scaffold, if new ----------
if (-not (Test-Path $familyDir)) {
  Step "Scaffolding analyzers/$Family"
  $scaffoldArgs = @{ Family = $Family }
  if ($Description) { $scaffoldArgs.Description = $Description }
  & (Join-Path $PSScriptRoot "new-analyzer.ps1") @scaffoldArgs
} else {
  Write-Host "analyzers/$Family already exists - skipping scaffold." -ForegroundColor DarkGray
}

# ---------- 2. Pull from Studio, if requested ----------
if ($AnalyzerId) {
  Step "Pulling '$AnalyzerId' from Studio ($Environment)"
  & (Join-Path $PSScriptRoot "sync-analyzer-from-studio.ps1") -Environment $Environment -Family $Family -AnalyzerId $AnalyzerId
} else {
  Write-Host ""
  Write-Host "No -AnalyzerId supplied - not pulling from Studio. Edit analyzers/$Family/analyzer.json by hand if needed." -ForegroundColor DarkGray
}

# ---------- 3. Refresh derived golden-set artifacts ----------
Step "Refreshing golden-set artifacts"
& (Join-Path $schemasDir "update-golden.ps1") -Family $Family

# ---------- 4. Validate just this family ----------
Step "Validating analyzers/$Family"
& (Join-Path $schemasDir "validate-analyzers.ps1") -Family $Family
$analyzerOk = ($LASTEXITCODE -eq 0)
& (Join-Path $schemasDir "validate-golden.ps1") -Family $Family
$goldenOk = ($LASTEXITCODE -eq 0)

Write-Host ""
if ($analyzerOk -and $goldenOk) {
  Write-Host "analyzers/$Family looks good." -ForegroundColor Green
} else {
  Write-Host "analyzers/$Family has issues reported above - fix them, then re-run this script (safe to re-run)." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Review analyzers/$Family/analyzer.json and add/verify golden/<name>.<ext> + <name>.expected.json pairs"
Write-Host "     (bootstrap-golden.ps1 can draft expected.json from a deployed analyzer's own output - see docs/getting-started.md)."
Write-Host "  2. git add analyzers/$Family && git commit -m `"Add $Family analyzer`""
Write-Host "  3. pwsh -File ./scripts/promote-analyzer.ps1 -Environment $Environment -Family $Family -Notes `"Initial deployment`""
Write-Host "  4. pwsh -File ./scripts/compare-analyzers.ps1 -Environment $Environment -Family $Family -AnalyzerIds ${Family}v1"
Write-Host "  5. git add analyzers/$Family/results && git commit -m `"Record ${Family}v1 evaluation`" && git push origin main"

exit ($(if ($analyzerOk -and $goldenOk) { 0 } else { 1 }))
