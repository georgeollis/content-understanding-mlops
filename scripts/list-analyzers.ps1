<#
.SYNOPSIS
  Lists Azure AI Content Understanding analyzers in a resource using the GA REST API (2025-11-01).

.DESCRIPTION
  Calls GET {endpoint}/contentunderstanding/analyzers and prints a summary table of analyzers
  (id, status, base analyzer, created date). By default only custom (non-prebuilt) analyzers
  are shown; use -IncludePrebuilt to see everything, or -Prebuilt to see only prebuilt ones.

  Authentication uses a Microsoft Entra ID access token (az account get-access-token),
  since resources with disableLocalAuth=true cannot use subscription keys.

.PARAMETER Environment
  Environment name (e.g. "dev", "test", "prod") as defined in environments.json at the repo
  root. Resolves -Endpoint automatically. Either -Environment or -Endpoint is required.

.PARAMETER Endpoint
  The Content Understanding resource endpoint, e.g. https://myresource.cognitiveservices.azure.com
  Overrides whatever -Environment would have resolved to.

.PARAMETER ApiVersion
  Content Understanding API version. Defaults to the current GA version.

.PARAMETER IncludePrebuilt
  Include built-in prebuilt-* analyzers in the listing (there are usually 80+, so omitted by default).

.PARAMETER Detailed
  Print the full JSON for each analyzer (fieldSchema, config, models, etc.) instead of the summary table.

.EXAMPLE
  .\list-analyzers.ps1 -Environment dev

.EXAMPLE
  .\list-analyzers.ps1 -Endpoint "https://<your-resource>.cognitiveservices.azure.com" -Detailed
#>
param(
  [string]$Environment,

  [string]$Endpoint,

  [string]$ApiVersion = "2025-11-01",

  [switch]$IncludePrebuilt,

  [switch]$Detailed
)

$ErrorActionPreference = "Stop"

if (-not $Environment -and -not $Endpoint) {
  throw "Provide -Environment <name> (see environments.json) or -Endpoint <url>."
}
if (-not $Endpoint) {
  $repoRootForEnv = Resolve-Path (Join-Path $PSScriptRoot "..")
  $envConfigPath = Join-Path $repoRootForEnv "environments.json"
  if (-not (Test-Path $envConfigPath)) { throw "Not found: $envConfigPath. Create it or pass -Endpoint directly." }
  $envConfig = Get-Content $envConfigPath -Raw | ConvertFrom-Json
  $envEntry = $envConfig.environments.$Environment
  if (-not $envEntry) { throw "Environment '$Environment' not found in $envConfigPath. Add it, or pass -Endpoint directly." }
  $Endpoint = $envEntry.endpoint
}

# 1. Get a Microsoft Entra ID access token for Cognitive Services
$token = az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv
if (-not $token) { throw "Failed to acquire access token. Run 'az login' first." }

$headers = @{ Authorization = "Bearer $token" }
$endpointTrimmed = $Endpoint.TrimEnd('/')
$uri = "$endpointTrimmed/contentunderstanding/analyzers?api-version=$ApiVersion"

$allAnalyzers = @()
while ($uri) {
  $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method GET
  $allAnalyzers += $response.value
  $uri = $response.nextLink
}

$filtered = if ($IncludePrebuilt) {
  $allAnalyzers
} else {
  $allAnalyzers | Where-Object { $_.analyzerId -notlike "prebuilt-*" }
}

Write-Host "Found $($filtered.Count) analyzer(s)$(if (-not $IncludePrebuilt) { ' (custom only, use -IncludePrebuilt to see all)' })." -ForegroundColor Cyan

if ($Detailed) {
  $filtered | ConvertTo-Json -Depth 10
} else {
  $filtered |
    Select-Object analyzerId, status, baseAnalyzerId, createdAt, description |
    Sort-Object createdAt |
    Format-Table -AutoSize
}
