<#
.SYNOPSIS
  Copies a family's labeled training data (used by knowledgeSources[].kind == "labeledData")
  from one environment's storage container to another.

.DESCRIPTION
  In Foundry Studio, labeling a document set for an analyzer stores the labeled files in a
  blob container attached to that environment's Content Understanding resource. That data is
  referenced by analyzer.json via a knowledgeSources[].containerUrl + prefix.

  Labeled data does NOT automatically exist in every environment - each Foundry account has
  its own storage. Promoting analyzer.json to a new environment (e.g. dev -> test) deploys the
  *analyzer*, but if that analyzer relies on labeled data, the underlying blobs must be copied
  to the target environment's storage BEFORE (or as part of) promotion, or the analyzer will
  fail to train/build correctly there.

  This script uses "azcopy" to copy every blob under -Prefix from the source environment's
  labeledDataContainerUrl to the destination environment's labeledDataContainerUrl (both read
  from environments.json), preserving the folder structure so the same -Prefix path works
  in both places.

  Requires: azcopy (https://aka.ms/azcopy) authenticated via 'azcopy login', or has access to
  both storage accounts via Entra ID (the identity running this script needs Storage Blob Data
  Reader on the source and Storage Blob Data Contributor on the destination).

.PARAMETER SourceEnvironment
  Environment name to copy labeled data FROM (e.g. "dev"), as defined in environments.json.

.PARAMETER DestinationEnvironment
  Environment name to copy labeled data TO (e.g. "test"), as defined in environments.json.

.PARAMETER Prefix
  The blob path prefix under each container holding this family's labeled data, e.g.
  "labelingProjects/599a5656-8624-47e1-8b94-0d1bec0a40b8/train" - copy this value directly out
  of analyzer.json's knowledgeSources[].prefix field for the family being promoted.

.EXAMPLE
  .\copy-labeled-data.ps1 -SourceEnvironment dev -DestinationEnvironment test `
    -Prefix "labelingProjects/599a5656-8624-47e1-8b94-0d1bec0a40b8/train"

.NOTES
  Run this BEFORE promote-analyzer.ps1 for the destination environment, so the labeled data is
  already in place by the time the analyzer is deployed there.
#>
param(
  [Parameter(Mandatory = $true)]
  [string]$SourceEnvironment,

  [Parameter(Mandatory = $true)]
  [string]$DestinationEnvironment,

  [Parameter(Mandatory = $true)]
  [string]$Prefix
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$envConfigPath = Join-Path $repoRoot "environments.json"
if (-not (Test-Path $envConfigPath)) { throw "Not found: $envConfigPath" }

$envConfig = Get-Content $envConfigPath -Raw | ConvertFrom-Json

$srcEntry = $envConfig.environments.$SourceEnvironment
$dstEntry = $envConfig.environments.$DestinationEnvironment
if (-not $srcEntry) { throw "Environment '$SourceEnvironment' not found in $envConfigPath." }
if (-not $dstEntry) { throw "Environment '$DestinationEnvironment' not found in $envConfigPath." }
if (-not $srcEntry.labeledDataContainerUrl) { throw "Environment '$SourceEnvironment' has no 'labeledDataContainerUrl' set in $envConfigPath." }
if (-not $dstEntry.labeledDataContainerUrl) { throw "Environment '$DestinationEnvironment' has no 'labeledDataContainerUrl' set in $envConfigPath." }

if (-not (Get-Command azcopy -ErrorAction SilentlyContinue)) {
  throw "azcopy not found on PATH. Install it from https://aka.ms/azcopy and run 'azcopy login' first."
}

$srcUrl = "$($srcEntry.labeledDataContainerUrl.TrimEnd('/'))/$Prefix"
$dstUrl = "$($dstEntry.labeledDataContainerUrl.TrimEnd('/'))/$Prefix"

Write-Host "Copying labeled data:" -ForegroundColor Cyan
Write-Host "  From ($SourceEnvironment): $srcUrl"
Write-Host "  To   ($DestinationEnvironment): $dstUrl"
Write-Host ""

azcopy copy "$srcUrl" "$dstUrl" --recursive

if ($LASTEXITCODE -ne 0) {
  throw "azcopy copy failed with exit code $LASTEXITCODE."
}

Write-Host ""
Write-Host "Done. Labeled data now exists at the same prefix in '$DestinationEnvironment'." -ForegroundColor Green
Write-Host "Next: promote the analyzer to $DestinationEnvironment - promote-analyzer.ps1 will" -ForegroundColor Cyan
Write-Host "automatically point containerUrl at this environment's storage."
