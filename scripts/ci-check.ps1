<#
.SYNOPSIS
  Single CI/pre-commit entrypoint: validates every analyzer definition and golden dataset.

.DESCRIPTION
  Runs, in order:
    1. schemas/validate-analyzers.ps1  - every analyzers/<family>/analyzer.json against
       schemas/analyzer.schema.json.
    2. schemas/validate-golden.ps1 -All - every family's golden set: checksums match
       manifest.json, and every expected.json conforms to expected.schema.json.

  This does NOT call Azure (no live comparison) - it's meant to be fast and run on every
  commit/PR. Use compare-analyzers.ps1 separately for live accuracy comparisons before promoting.

  To refresh analyzers/README.md's family index table, run
  schemas/list-families.ps1 -WriteReadme manually - it is not part of this check and never
  fails CI.

.PARAMETER Fix
  Before validating, regenerate every family's derived golden-set artifacts
  (expected.schema.json + manifest.json via schemas/update-golden.ps1 -All), so a stale
  checksum or schema from an edited/added/removed golden doc heals itself instead of failing.
  Does not touch anything that requires human judgment (e.g. an unreviewed "_bootstrap" marker,
  or a genuinely missing/renamed field) - those still fail and must be fixed by hand.

.EXAMPLE
  .\ci-check.ps1

.EXAMPLE
  .\ci-check.ps1 -Fix

.NOTES
  Requires PowerShell 7+ (pwsh). No Python or external packages required.
#>
param(
  [switch]$Fix
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$schemasDir = Join-Path $repoRoot "schemas"

$failed = $false

function Run-Check {
  param([string]$Name, [scriptblock]$Block)
  Write-Host "==> $Name" -ForegroundColor Cyan
  & $Block
  if ($LASTEXITCODE -ne 0) {
    Write-Host "FAILED: $Name" -ForegroundColor Red
    $script:failed = $true
  } else {
    Write-Host "PASSED: $Name" -ForegroundColor Green
  }
  Write-Host ""
}

Run-Check "Analyzer schema validation" {
  & (Join-Path $schemasDir "validate-analyzers.ps1")
}

if ($Fix) {
  Write-Host "==> Refreshing golden-set artifacts (-Fix)" -ForegroundColor Cyan
  & (Join-Path $schemasDir "update-golden.ps1") -All | Out-Null
  Write-Host ""
}

Run-Check "Golden dataset validation" {
  & (Join-Path $schemasDir "validate-golden.ps1") -All
}

if ($failed) {
  Write-Host "One or more checks failed." -ForegroundColor Red
  exit 1
} else {
  Write-Host "All checks passed." -ForegroundColor Green
  exit 0
}
