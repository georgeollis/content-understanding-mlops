<#
.SYNOPSIS
  Promotes the current analyzers/<family>/analyzer.json to a new versioned Azure deployment,
  tags the git commit, and records the promotion in that environment's manifest file.

.DESCRIPTION
  Local analyzer definitions are version-controlled as a single mutable file per family
  (analyzers/<family>/analyzer.json) - history lives in git, not in duplicate vN.json files.
  "Versions" only need to materialize as distinct objects when you deploy to Azure, because
  compare-analyzers.ps1 needs multiple live analyzerIds to diff against each other and against
  the golden set.

  Each environment (dev/test/prod, ...) is a separate Foundry account with its own endpoint and
  its own manifest.<environment>.json - promoting to "test" does NOT create the analyzer in
  "dev" or "prod". Merging analyzer.json across git branches only changes the file; you must
  still run this script against each environment's endpoint to actually deploy it there.

  This script:
    1. Reads analyzers/<family>/analyzer.json and analyzers/<family>/manifest.<Environment>.json.
    2. Determines the next version number for THIS environment (max existing promotion + 1).
    3. Requires a clean git working tree for this file (so the tag points at an exact,
       reviewable commit) unless -AllowDirty is passed.
    4. If analyzer.json references labeled training data (knowledgeSources[].kind ==
       "labeledData"), rewrites containerUrl to this environment's labeledDataContainerUrl
       (from environments.json) before deploying - see copy-labeled-data.ps1 for how the
       actual blob data gets copied to each environment's storage account.
    5. Uploads analyzer.json to Azure as "<family>V<N>" via upload-analyzers.ps1.
    6. Creates an annotated git tag "<family>-<environment>-v<N>" at the current commit.
    7. Appends a new entry to manifest.<Environment>.json's "promotions" array and updates
       "current".

.PARAMETER Environment
  Environment name (e.g. "dev", "test", "prod") as defined in environments.json at the repo
  root. Resolves -Endpoint automatically. Either -Environment or -Endpoint is required.

.PARAMETER Endpoint
  The Content Understanding resource endpoint, e.g. https://myresource.cognitiveservices.azure.com
  Overrides whatever -Environment would have resolved to. Required if -Environment is omitted.

.PARAMETER Family
  The analyzer family folder name under analyzers/, e.g. "invoice".

.PARAMETER Notes
  Free-text note describing what changed in this promotion (stored in the manifest).

.PARAMETER AllowDirty
  Skip the clean-working-tree check (not recommended - the whole point of tagging is that the
  deployed analyzerId maps to an exact, reviewable git commit).

.PARAMETER ApiVersion
  Content Understanding API version. Defaults to the current GA version.

.EXAMPLE
  # After editing analyzers/invoice/analyzer.json and committing the change:
  .\promote-analyzer.ps1 -Environment dev -Family invoice -Notes "Adds BusinessPhone and ClientPhone fields."

.EXAMPLE
  # Deploy the same, already-committed analyzer.json to test once it's approved there.
  .\promote-analyzer.ps1 -Environment test -Family invoice -Notes "Promote to test."

.NOTES
  Compare the new version against a previous one before (or after) promoting with:
    .\compare-analyzers.ps1 -Environment dev -Family invoice -AnalyzerIds invoicev1, invoicev2
#>
param(
  [string]$Environment,

  [string]$Endpoint,

  [Parameter(Mandatory = $true)]
  [string]$Family,

  [Parameter(Mandatory = $true)]
  [string]$Notes,

  [switch]$AllowDirty,

  [string]$ApiVersion = "2025-11-01"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$familyDir = Join-Path $repoRoot "analyzers\$Family"
$analyzerFile = Join-Path $familyDir "analyzer.json"

if (-not $Environment -and -not $Endpoint) {
  throw "Provide -Environment <name> (see environments.json) or -Endpoint <url>."
}

$labeledDataContainerUrl = $null
if (-not $Endpoint) {
  $envConfigPath = Join-Path $repoRoot "environments.json"
  if (-not (Test-Path $envConfigPath)) { throw "Not found: $envConfigPath. Create it or pass -Endpoint directly." }
  $envConfig = Get-Content $envConfigPath -Raw | ConvertFrom-Json
  $envEntry = $envConfig.environments.$Environment
  if (-not $envEntry) { throw "Environment '$Environment' not found in $envConfigPath. Add it, or pass -Endpoint directly." }
  $Endpoint = $envEntry.endpoint
  $labeledDataContainerUrl = $envEntry.labeledDataContainerUrl
}

if (-not $Environment) { $Environment = "default" }

$manifestFile = Join-Path $familyDir "manifest.$Environment.json"

if (-not (Test-Path $analyzerFile)) { throw "Not found: $analyzerFile" }
if (-not (Test-Path $manifestFile)) { throw "Not found: $manifestFile (expected one manifest file per environment - copy manifest.dev.json as a starting template if this is a new environment)" }

# ---------- Git safety check ----------
Push-Location $repoRoot
try {
  $relPath = "analyzers/$Family/analyzer.json"
  $dirty = git status --porcelain -- $relPath
  if ($dirty -and -not $AllowDirty) {
    throw "Uncommitted changes in $relPath. Commit them first (so the git tag points at an exact, reviewable version), or pass -AllowDirty to override."
  }

  $commitSha = (git rev-parse --short HEAD).Trim()
}
finally {
  Pop-Location
}

# ---------- Determine next version (per environment) ----------
$manifest = Get-Content $manifestFile -Raw | ConvertFrom-Json
$existingVersions = @($manifest.promotions | ForEach-Object { $_.version })
$nextVersion = if ($existingVersions.Count -gt 0) { ($existingVersions | Measure-Object -Maximum).Maximum + 1 } else { 1 }
$analyzerId = ("$Family" + "v$nextVersion").ToLowerInvariant()
$gitTag = "$Family-$Environment-v$nextVersion".ToLowerInvariant()

Write-Host "Promoting $Family analyzer.json (commit $commitSha) to environment '$Environment' as '$analyzerId' (tag '$gitTag')..." -ForegroundColor Cyan

# ---------- Rewrite knowledgeSources for this environment (labeled data) ----------
# analyzer.json is shared across all environments. If it references labeled training data
# (knowledgeSources[].kind == "labeledData"), its containerUrl points at ONE environment's
# storage account. Before deploying, rewrite it to point at the CURRENT environment's
# container (from environments.json), so the same analyzer.json works everywhere as long as
# each environment has a copy of the labeled data at the same blob path (see
# copy-labeled-data.ps1). The rewritten file is only used for this deploy - the source
# analyzer.json on disk is never modified.
$analyzerDef = Get-Content $analyzerFile -Raw | ConvertFrom-Json
$deployFile = $analyzerFile
$hasLabeledData = $analyzerDef.knowledgeSources | Where-Object { $_.kind -eq "labeledData" }
if ($hasLabeledData) {
  if (-not $labeledDataContainerUrl) {
    Write-Host "  WARNING: analyzer.json references labeled data, but environment '$Environment' has no 'labeledDataContainerUrl' set in environments.json. Deploying with the containerUrl already in analyzer.json (may point at the wrong environment's storage)." -ForegroundColor Yellow
  } else {
    foreach ($src in $analyzerDef.knowledgeSources) {
      if ($src.kind -eq "labeledData") {
        Write-Host "  Rewriting labeled-data containerUrl -> $labeledDataContainerUrl (environment '$Environment')"
        $src.containerUrl = $labeledDataContainerUrl
      }
    }
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "cu-promote-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    $deployFile = Join-Path $tempDir "analyzer.json"
    $analyzerDef | ConvertTo-Json -Depth 20 | Set-Content $deployFile -Encoding utf8
  }
}

# ---------- Deploy to Azure ----------
& (Join-Path $PSScriptRoot "upload-analyzers.ps1") `
  -Endpoint $Endpoint `
  -AnalyzerFiles $deployFile `
  -AnalyzerIds $analyzerId `
  -ApiVersion $ApiVersion

# ---------- Tag the commit ----------
Push-Location $repoRoot
try {
  git tag -a $gitTag -m "$Family v${nextVersion} ($Environment): $Notes"
  Write-Host "Created git tag '$gitTag'. Push it with: git push origin $gitTag" -ForegroundColor Yellow
}
finally {
  Pop-Location
}

# ---------- Update manifest.<Environment>.json ----------
foreach ($p in $manifest.promotions) {
  if ($p.status -eq "active") { $p.status = "superseded" }
}

$newPromotion = [ordered]@{
  version    = $nextVersion
  analyzerId = $analyzerId
  gitTag     = $gitTag
  commit     = $commitSha
  createdAt  = (Get-Date -Format "yyyy-MM-dd")
  status     = "active"
  notes      = $Notes
}

$promotions = @($manifest.promotions) + [pscustomobject]$newPromotion
$manifest.promotions = $promotions
$manifest.current = $analyzerId

$manifest | ConvertTo-Json -Depth 10 | Set-Content $manifestFile -Encoding utf8

Write-Host "Updated $manifestFile - current ($Environment) = $analyzerId" -ForegroundColor Green
Write-Host ""
Write-Host "Next: compare against the previous version with:" -ForegroundColor Cyan
Write-Host "  .\compare-analyzers.ps1 -Endpoint $Endpoint -Family $Family -AnalyzerIds <previousId>, $analyzerId"
