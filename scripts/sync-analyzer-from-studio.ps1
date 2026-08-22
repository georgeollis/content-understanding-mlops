<#
.SYNOPSIS
  Pulls the current live definition of a dev-environment analyzer from Foundry Studio back into
  the local analyzers/<family>/analyzer.json, for review and commit.

.DESCRIPTION
  Studio is the recommended tool for ongoing interactive authoring in "dev" (see
  docs/mlops-pipeline.md#authoring-studio-dev-vs-this-repo-dev). Rather than a one-time export,
  this script lets you keep iterating directly in Studio against the dev Foundry account for as
  long as you want, then pull the current state down whenever you're ready to commit it.

  This is a read-only GET against Azure - it never deploys anything. It calls
  GET /analyzers/{analyzerId} on the dev environment, strips fields that aren't part of the
  local "source of truth" shape (analyzerId, createdAt, lastModifiedAt, status, warnings,
  supportedModels - see schemas/analyzer.schema.json's ContentAnalyzer definition for the exact
  request-body shape), and overwrites analyzers/<family>/analyzer.json with the result.

  This does NOT create a new officially tracked/tagged deployment - after reviewing and
  committing the pulled file, run promote-analyzer.ps1 -Environment dev as usual to record it
  as a proper versioned, git-tagged promotion. That keeps every entry in manifest.dev.json
  backed by an exact, reviewable git commit, even though the analyzer was actually designed
  live in Studio.

  Restricted to the "dev" environment (or -Endpoint pointed at whatever your dev account is):
  test/prod/etc. must only ever be reached via promote-analyzer.ps1, never Studio, never this
  script - pass -AllowNonDev to override, but doing so defeats the entire promotion model for
  that environment (its deployed state would no longer map to a git-tagged commit).

.PARAMETER Environment
  Environment name as defined in environments.json. Must be "dev" unless -AllowNonDev is
  passed. Either -Environment or -Endpoint is required.

.PARAMETER Endpoint
  The Content Understanding resource endpoint. Overrides -Environment.

.PARAMETER Family
  The analyzer family folder name under analyzers/, e.g. "invoice". Must already exist.

.PARAMETER AnalyzerId
  The analyzerId currently live in Studio to pull from. If omitted, defaults to
  manifest.dev.json's "current" analyzerId.

.PARAMETER AllowNonDev
  Override the dev-only restriction. Not recommended - see DESCRIPTION.

.PARAMETER ApiVersion
  Content Understanding API version. Defaults to the current GA version.

.EXAMPLE
  # After iterating on the "invoice" analyzer directly in Studio (dev):
  .\sync-analyzer-from-studio.ps1 -Environment dev -Family invoice -AnalyzerId invoicev4
  git diff analyzers/invoice/analyzer.json
  # ...fix golden-set drift if fields changed, then:
  git add analyzers/invoice/analyzer.json
  git commit -m "invoice: pull Studio edits (added PaymentTerms field)"
  .\promote-analyzer.ps1 -Environment dev -Family invoice -Notes "Studio edit: added PaymentTerms"

.NOTES
  Full workflow: docs/mlops-pipeline.md#authoring-studio-dev-vs-this-repo-dev
#>
param(
  [string]$Environment,

  [string]$Endpoint,

  [Parameter(Mandatory = $true)]
  [string]$Family,

  [string]$AnalyzerId,

  [switch]$AllowNonDev,

  [string]$ApiVersion = "2025-11-01"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$familyDir = Join-Path $repoRoot "analyzers\$Family"
$analyzerFile = Join-Path $familyDir "analyzer.json"

if (-not (Test-Path $familyDir)) { throw "Family folder not found: $familyDir. Create it first (see analyzers/_template)." }

if (-not $Environment -and -not $Endpoint) {
  throw "Provide -Environment <name> (see environments.json) or -Endpoint <url>."
}
if ($Environment -and $Environment -ne "dev" -and -not $AllowNonDev) {
  throw "sync-analyzer-from-studio.ps1 is restricted to the 'dev' environment (Studio is only used for dev-scoped authoring). Pass -AllowNonDev to override - not recommended, this breaks the promotion model for '$Environment'."
}

if (-not $Endpoint) {
  $envConfigPath = Join-Path $repoRoot "environments.json"
  if (-not (Test-Path $envConfigPath)) { throw "Not found: $envConfigPath. Create it or pass -Endpoint directly." }
  $envConfig = Get-Content $envConfigPath -Raw | ConvertFrom-Json
  $envEntry = $envConfig.environments.$Environment
  if (-not $envEntry) { throw "Environment '$Environment' not found in $envConfigPath. Add it, or pass -Endpoint directly." }
  $Endpoint = $envEntry.endpoint
}
if (-not $Environment) { $Environment = "default" }

# ---------- Resolve which analyzerId to pull ----------
if (-not $AnalyzerId) {
  $manifestFile = Join-Path $familyDir "manifest.$Environment.json"
  if (-not (Test-Path $manifestFile)) {
    throw "No -AnalyzerId given and $manifestFile doesn't exist. Pass -AnalyzerId <id> explicitly (the analyzerId currently live in Studio)."
  }
  $manifest = Get-Content $manifestFile -Raw | ConvertFrom-Json
  if (-not $manifest.current) {
    throw "No -AnalyzerId given and manifest.$Environment.json has no 'current' analyzerId. Pass -AnalyzerId <id> explicitly."
  }
  $AnalyzerId = $manifest.current
  Write-Host "No -AnalyzerId given; using '$AnalyzerId' from manifest.$Environment.json's 'current'." -ForegroundColor DarkGray
}

$token = az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv
if (-not $token) { throw "Failed to acquire access token. Run 'az login' first." }
$endpointTrimmed = $Endpoint.TrimEnd('/')

# ---------- Pull the live analyzer definition ----------
$headers = @{ Authorization = "Bearer $token" }
$uri = "$endpointTrimmed/contentunderstanding/analyzers/$AnalyzerId`?api-version=$ApiVersion"

Write-Host "Fetching '$AnalyzerId' from $endpointTrimmed ..." -ForegroundColor Cyan
$live = Invoke-RestMethod -Uri $uri -Headers $headers -Method GET

# ---------- Strip to the canonical local shape (see schemas/analyzer.schema.json ContentAnalyzer) ----------
# Drops read-only/server-populated fields (analyzerId, createdAt, lastModifiedAt, status,
# warnings, supportedModels) that aren't part of the PUT /analyzers/{id} request body and would
# otherwise pollute source control with values that were never authored, just observed.
$canonicalKeyOrder = @(
  "description", "tags", "baseAnalyzerId", "config", "models", "fieldSchema",
  "dynamicFieldSchema", "processingLocation", "knowledgeSources"
)

$cleaned = [ordered]@{}
foreach ($key in $canonicalKeyOrder) {
  if ($live.PSObject.Properties.Name -contains $key) {
    $cleaned[$key] = $live.$key
  }
}

$droppedKeys = @($live.PSObject.Properties.Name | Where-Object { $canonicalKeyOrder -notcontains $_ })
if ($droppedKeys.Count -gt 0) {
  Write-Host "Dropped Studio/API-only fields not part of the local source-of-truth shape: $($droppedKeys -join ', ')" -ForegroundColor DarkGray
}

$hadExisting = Test-Path $analyzerFile
$newJson = ($cleaned | ConvertTo-Json -Depth 20)
$cleaned | ConvertTo-Json -Depth 20 | Set-Content -Path $analyzerFile -Encoding utf8

Write-Host ""
Write-Host "Wrote $analyzerFile from live analyzerId '$AnalyzerId'." -ForegroundColor Green
if ($hadExisting) {
  Write-Host "Review the change with:" -ForegroundColor Yellow
  Write-Host "  git diff analyzers/$Family/analyzer.json"
} else {
  Write-Host "This is a new file - review it against schemas/analyzer.schema.json before committing." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. If fieldSchema changed, re-run: pwsh -File .\schemas\build-ground-truth-schema.ps1 -Family $Family"
Write-Host "     and:                            pwsh -File .\schemas\sync-golden-fields.ps1 -Family $Family"
Write-Host "  2. pwsh -File .\scripts\ci-check.ps1"
Write-Host "  3. git add analyzers/$Family/analyzer.json `&`& git commit -m `"$Family`: pull Studio edits`""
Write-Host "  4. pwsh -File .\scripts\promote-analyzer.ps1 -Environment dev -Family $Family -Notes `"...`""
Write-Host "     (this creates the next official, git-tagged dev version from what you just pulled)"
