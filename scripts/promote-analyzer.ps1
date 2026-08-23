<#
.SYNOPSIS
  Promotes the current analyzers/<family>/analyzer.json to a new versioned Azure deployment
  and records the promotion in that environment's manifest file.

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
    3. If analyzer.json references labeled training data (knowledgeSources[].kind ==
       "labeledData"), rewrites containerUrl to this environment's labeledDataContainerUrl
       (from environments.json) before deploying - see copy-labeled-data.ps1 for how the
       actual blob data gets copied to each environment's storage account.
    4. Uploads analyzer.json to Azure as "<family>V<N>" via upload-analyzers.ps1.
    5. Appends a new entry to manifest.<Environment>.json's "promotions" array and updates
       "current".

.PARAMETER Environment
  Environment name (e.g. "dev", "test", "prod"). Resolves -Endpoint automatically from
  analyzers/<family>/environments.json when present, otherwise from repo-root
  environments.json. Either -Environment or -Endpoint is required.

.PARAMETER Endpoint
  The Content Understanding resource endpoint, e.g. https://myresource.cognitiveservices.azure.com
  Overrides whatever -Environment would have resolved to. Required if -Environment is omitted.

.PARAMETER Family
  The analyzer family folder name under analyzers/, e.g. "invoice".

.PARAMETER Notes
  Free-text note describing what changed in this promotion (stored in the manifest).

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

  [string]$ApiVersion = "2025-11-01"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$familyDir = Join-Path $repoRoot "analyzers" $Family
$analyzerFile = Join-Path $familyDir "analyzer.json"

if (-not $Environment -and -not $Endpoint) {
  throw "Provide -Environment <name> (see analyzer or repo environments.json) or -Endpoint <url>."
}

. (Join-Path $PSScriptRoot "lib" "EnvironmentConfig.ps1")

$labeledDataContainerUrl = $null
if (-not $Endpoint) {
  $resolvedEnv = Resolve-EnvironmentConfigEntry -RepoRoot $repoRoot -Environment $Environment -Family $Family
  $envEntry = $resolvedEnv.Entry
  $Endpoint = $envEntry.endpoint
  if (-not $Endpoint) { throw "Environment '$Environment' in $($resolvedEnv.Path) is missing 'endpoint'. Add it, or pass -Endpoint directly." }
  $labeledDataContainerUrl = $envEntry.labeledDataContainerUrl
}

if (-not $Environment) { $Environment = "default" }

$manifestFile = Join-Path $familyDir "manifest.$Environment.json"

if (-not (Test-Path $analyzerFile)) { throw "Not found: $analyzerFile" }
if (-not (Test-Path $manifestFile)) { throw "Not found: $manifestFile (expected one manifest file per environment - copy manifest.dev.json as a starting template if this is a new environment)" }

# Content Understanding rejects analyzerIds containing "-" (even though its own API docs list
# hyphens as allowed), and the family name becomes part of every deployed analyzerId
# ("<family>v<N>") - fail fast with a clear message instead of letting Azure reject the PUT.
if ($Family -match "-") {
  throw "Family '$Family' contains a hyphen, which Content Understanding does not allow in analyzerIds. Rename the analyzers/$Family folder to a hyphen-free name (e.g. '$($Family -replace '-', '')') and try again."
}

# ---------- Determine next version (per environment) ----------
$manifest = Get-Content $manifestFile -Raw | ConvertFrom-Json
$existingVersions = @($manifest.promotions | ForEach-Object { $_.version })
$nextVersion = if ($existingVersions.Count -gt 0) { ($existingVersions | Measure-Object -Maximum).Maximum + 1 } else { 1 }
$analyzerId = ("$Family" + "v$nextVersion").ToLowerInvariant()

Write-Host "Promoting $Family analyzer.json to environment '$Environment' as '$analyzerId'..." -ForegroundColor Cyan

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
    Write-Host "  WARNING: analyzer.json references labeled data, but environment '$Environment' has no 'labeledDataContainerUrl' set in analyzer/root environments.json. Deploying with the containerUrl already in analyzer.json (may point at the wrong environment's storage)." -ForegroundColor Yellow
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

# ---------- Update manifest.<Environment>.json ----------
foreach ($p in $manifest.promotions) {
  if ($p.status -eq "active") { $p.status = "superseded" }
}

$newPromotion = [ordered]@{
  version    = $nextVersion
  analyzerId = $analyzerId
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
