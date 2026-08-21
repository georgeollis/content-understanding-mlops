<#
.SYNOPSIS
  Uploads (creates or replaces) Azure AI Content Understanding analyzer definitions
  from local JSON files using the GA REST API (2025-11-01).

.DESCRIPTION
  For each JSON file passed in, this script:
    1. Reads the analyzer definition from disk.
    2. PUTs it to {endpoint}/contentunderstanding/analyzers/{analyzerId}
    3. Polls the returned Operation-Location until the analyzer is "ready" or "failed".

  Authentication uses a Microsoft Entra ID access token (az account get-access-token),
  since resources with disableLocalAuth=true cannot use subscription keys.

.PARAMETER Endpoint
  The Content Understanding resource endpoint, e.g. https://myresource.cognitiveservices.azure.com

.PARAMETER AnalyzerFiles
  One or more paths to local JSON analyzer definitions. The analyzerId is derived from the
  file name (without extension) unless -AnalyzerIds is supplied in the same order.

.PARAMETER AnalyzerIds
  Optional explicit analyzer IDs matching each file in -AnalyzerFiles (same order/count).

.PARAMETER ApiVersion
  Content Understanding API version. Defaults to the current GA version.

.EXAMPLE
  # Manual one-off upload (prefer scripts\promote-analyzer.ps1 for tracked promotions):
  .\upload-analyzers.ps1 -Endpoint "https://byofoundrylfgymnr5a.cognitiveservices.azure.com" `
    -AnalyzerFiles ".\analyzers\invoiceHeader\analyzer.json", ".\analyzers\complaintForm\analyzer.json" `
    -AnalyzerIds "invoiceHeaderDev", "complaintFormDev"

.NOTES
  Analyzer IDs must match ^[a-zA-Z0-9._]{1,64}$ - hyphens are rejected by the service even
  though the API docs list them as allowed, so use -AnalyzerIds to override file-name-derived
  defaults when your file names contain dashes.
#>
param(
  [Parameter(Mandatory = $true)]
  [string]$Endpoint,

  [Parameter(Mandatory = $true)]
  [string[]]$AnalyzerFiles,

  [string[]]$AnalyzerIds,

  [string]$ApiVersion = "2025-11-01"
)

$ErrorActionPreference = "Stop"

# 1. Get a Microsoft Entra ID access token for Cognitive Services
$token = az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv
if (-not $token) { throw "Failed to acquire access token. Run 'az login' first." }

$headers = @{
  Authorization  = "Bearer $token"
  "Content-Type" = "application/json"
}

$endpointTrimmed = $Endpoint.TrimEnd('/')

for ($i = 0; $i -lt $AnalyzerFiles.Count; $i++) {
  $file = $AnalyzerFiles[$i]
  if (-not (Test-Path $file)) { throw "File not found: $file" }

  $analyzerId = if ($AnalyzerIds -and $AnalyzerIds.Count -gt $i) {
    $AnalyzerIds[$i]
  } else {
    [System.IO.Path]::GetFileNameWithoutExtension($file)
  }

  $body = Get-Content $file -Raw
  $uri = "$endpointTrimmed/contentunderstanding/analyzers/$analyzerId`?api-version=$ApiVersion&allowReplace=true"

  Write-Host "Uploading '$file' as analyzer '$analyzerId'..."
  $response = Invoke-WebRequest -Uri $uri -Headers $headers -Method PUT -Body $body
  $opLocation = $response.Headers['Operation-Location'][0]

  # 2. Poll the long-running operation until it completes
  do {
    Start-Sleep -Seconds 3
    $op = Invoke-RestMethod -Uri $opLocation -Headers $headers -Method GET
    Write-Host "  status: $($op.status)"
  } while ($op.status -eq "Running" -or $op.status -eq "NotStarted")

  if ($op.status -eq "Succeeded") {
    Write-Host "  Analyzer '$analyzerId' is ready." -ForegroundColor Green
  } else {
    Write-Host "  Analyzer '$analyzerId' FAILED: $($op.error | ConvertTo-Json -Depth 5)" -ForegroundColor Red
  }
}
