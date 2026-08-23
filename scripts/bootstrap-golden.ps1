<#
.SYNOPSIS
  Bootstraps starting "<name>.expected.json" ground-truth files for a golden set by running a
  live analyzerId against each PDF and using its own extraction as a draft.

.DESCRIPTION
  Hand-writing expected.json from scratch for every golden document doesn't scale, especially
  once a family has more than a handful of fields or documents. This script instead calls
  POST /analyzers/{id}:analyzeBinary against an already-deployed analyzerId (e.g. right after
  the first promote-analyzer.ps1 run) for every "<name>.pdf" in the golden folder that doesn't
  already have a "<name>.expected.json", and writes the analyzer's own output as the starting
  file.

  This is NOT a substitute for review: the analyzer's output can be wrong, and expected.json is
  the ground truth compare-analyzers.ps1 scores against. Every file this script writes has
  "_bootstrap": true injected at the top (removed once you've reviewed it) as a reminder, and
  golden/manifest.json's groundTruthSource stays "generated" (see build-golden-manifest.ps1)
  until you change it to "human-verified" for a document you've checked against the source PDF.

  Existing expected.json files are never overwritten unless -Force is passed.

.PARAMETER Environment
  Environment name (e.g. "dev") as defined in environments.json. Resolves -Endpoint
  automatically. Either -Environment or -Endpoint is required.

.PARAMETER Endpoint
  The Content Understanding resource endpoint. Overrides -Environment.

.PARAMETER Family
  Analyzer family folder name under analyzers/, e.g. "invoice".

.PARAMETER AnalyzerId
  The deployed analyzerId to bootstrap from (e.g. "invoicev1"). Must already exist in the
  target environment - promote-analyzer.ps1 at least once before running this.

.PARAMETER Force
  Overwrite existing expected.json files too (re-bootstraps everything from the live analyzer's
  current output). Without this, only PDFs missing an expected.json are processed.

.PARAMETER ApiVersion
  Content Understanding API version. Defaults to the current GA version.

.EXAMPLE
  # After promoting invoicev1 for the first time, bootstrap ground truth for any golden PDFs
  # that don't have one yet:
  .\bootstrap-golden.ps1 -Environment dev -Family invoice -AnalyzerId invoicev1

.NOTES
  Review every generated file against its source PDF before trusting it - see
  docs/mlops-pipeline.md#bootstrapping-and-maintaining-the-golden-set.
#>
param(
  [string]$Environment,

  [string]$Endpoint,

  [Parameter(Mandatory = $true)]
  [string]$Family,

  [Parameter(Mandatory = $true)]
  [string]$AnalyzerId,

  [switch]$Force,

  [string]$ApiVersion = "2025-11-01"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$goldenDir = Join-Path $repoRoot "analyzers" $Family "golden"
if (-not (Test-Path $goldenDir)) { throw "Golden directory not found: $goldenDir" }

if (-not $Environment -and -not $Endpoint) {
  throw "Provide -Environment <name> (see environments.json) or -Endpoint <url>."
}
if (-not $Endpoint) {
  $envConfigPath = Join-Path $repoRoot "environments.json"
  if (-not (Test-Path $envConfigPath)) { throw "Not found: $envConfigPath. Create it or pass -Endpoint directly." }
  $envConfig = Get-Content $envConfigPath -Raw | ConvertFrom-Json
  $envEntry = $envConfig.environments.$Environment
  if (-not $envEntry) { throw "Environment '$Environment' not found in $envConfigPath. Add it, or pass -Endpoint directly." }
  $Endpoint = $envEntry.endpoint
}

$token = az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv
if (-not $token) { throw "Failed to acquire access token. Run 'az login' first." }
$endpointTrimmed = $Endpoint.TrimEnd('/')

# ---------- Same field-flattening logic as compare-analyzers.ps1 ----------
function ConvertFrom-ContentField {
  param($field)
  if ($null -eq $field) { return $null }
  switch ($field.type) {
    "string"  { return $field.valueString }
    "date"    { return $field.valueDate }
    "time"    { return $field.valueTime }
    "number"  { return $field.valueNumber }
    "integer" { return $field.valueInteger }
    "boolean" { return $field.valueBoolean }
    "array"   { return @($field.valueArray | ForEach-Object { ConvertFrom-ContentField $_ }) }
    "object"  {
      $obj = [ordered]@{}
      if ($field.valueObject) {
        foreach ($p in $field.valueObject.PSObject.Properties) {
          $obj[$p.Name] = ConvertFrom-ContentField $p.Value
        }
      }
      return $obj
    }
    "json"    { return $field.valueJson }
    default   { return $null }
  }
}

function Get-FlatFields {
  param($fieldsObject)
  $flat = [ordered]@{}
  if ($fieldsObject) {
    foreach ($p in $fieldsObject.PSObject.Properties) {
      $flat[$p.Name] = ConvertFrom-ContentField $p.Value
    }
  }
  return $flat
}

function Invoke-AnalyzeBinary {
  param([string]$FilePath)

  $bytes = [System.IO.File]::ReadAllBytes($FilePath)
  $headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/pdf" }
  $uri = "$endpointTrimmed/contentunderstanding/analyzers/$AnalyzerId`:analyzeBinary?api-version=$ApiVersion"

  $response = Invoke-WebRequest -Uri $uri -Headers $headers -Method POST -Body $bytes
  $opLocation = $response.Headers['Operation-Location'][0]

  $getHeaders = @{ Authorization = "Bearer $token" }
  do {
    Start-Sleep -Seconds 2
    $op = Invoke-RestMethod -Uri $opLocation -Headers $getHeaders -Method GET
  } while ($op.status -eq "NotStarted" -or $op.status -eq "Running")

  if ($op.status -ne "Succeeded") {
    throw "Analyze failed for '$AnalyzerId' on '$FilePath': $($op.error | ConvertTo-Json -Depth 5)"
  }

  return Get-FlatFields $op.result.contents[0].fields
}

# ---------- Bootstrap ----------
$pdfs = Get-ChildItem $goldenDir -Filter "*.pdf" | Sort-Object Name
if ($pdfs.Count -eq 0) { throw "No PDF files found in $goldenDir" }

$written = 0
$skipped = 0
foreach ($pdf in $pdfs) {
  $baseName = [System.IO.Path]::GetFileNameWithoutExtension($pdf.Name)
  $expectedPath = Join-Path $goldenDir "$baseName.expected.json"

  if ((Test-Path $expectedPath) -and -not $Force) {
    Write-Host "Skipping $baseName - expected.json already exists (use -Force to overwrite)" -ForegroundColor DarkGray
    $skipped++
    continue
  }

  Write-Host "Bootstrapping $baseName from '$AnalyzerId'..." -NoNewline
  $flat = Invoke-AnalyzeBinary -FilePath $pdf.FullName

  # Ordered so "_bootstrap" is impossible to miss at the top of the file, and is the first
  # thing a reviewer should delete once they've verified this document's values.
  $draft = [ordered]@{ _bootstrap = "GENERATED from analyzerId '$AnalyzerId' on $(Get-Date -AsUTC -Format 'o') - review every value against the source PDF, then delete this key." }
  foreach ($k in $flat.Keys) { $draft[$k] = $flat[$k] }

  $draft | ConvertTo-Json -Depth 20 | Set-Content -Path $expectedPath -Encoding utf8
  Write-Host " wrote $baseName.expected.json"
  $written++
}

Write-Host ""
Write-Host "Bootstrapped $written file(s), skipped $skipped existing file(s)." -ForegroundColor Cyan
if ($written -gt 0) {
  Write-Host "Next:" -ForegroundColor Yellow
  Write-Host "  1. Open each new <name>.pdf alongside its expected.json and correct any wrong values."
  Write-Host "  2. Delete the '_bootstrap' key once a document has been reviewed."
  Write-Host "  3. pwsh -File ./schemas/build-golden-manifest.ps1 -Family $Family"
  Write-Host "  4. Mark reviewed documents 'human-verified' in golden/manifest.json's groundTruthSource field."
  Write-Host "  5. pwsh -File ./scripts/ci-check.ps1"
}
