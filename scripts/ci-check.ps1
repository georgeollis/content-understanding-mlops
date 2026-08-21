<#
.SYNOPSIS
  Single CI/pre-commit entrypoint: validates every analyzer definition and golden dataset.

.DESCRIPTION
  Runs, in order:
    1. schemas/validate-analyzers.ps1  - every analyzers/<family>/analyzer.json against
       schemas/analyzer.schema.json.
    2. schemas/validate-golden.ps1 -All - every family's golden set: checksums match
       manifest.json, and every expected.json conforms to expected.schema.json.
    3. Regenerates the analyzers/README.md family index (schemas/list-families.ps1) and fails
       if it produces a diff that wasn't committed, so the index can't silently go stale.

  This does NOT call Azure (no live comparison) - it's meant to be fast and run on every
  commit/PR. Use compare-analyzers.ps1 separately for live accuracy comparisons before promoting.

.PARAMETER SkipIndexCheck
  Skip the analyzers/README.md staleness check (e.g. if running outside git, or intentionally
  mid-edit).

.EXAMPLE
  .\ci-check.ps1

.NOTES
  Requires PowerShell 7+ (pwsh). No Python or external packages required.
#>
param(
  [switch]$SkipIndexCheck
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

Run-Check "Golden dataset validation" {
  & (Join-Path $schemasDir "validate-golden.ps1") -All
}

if (-not $SkipIndexCheck) {
  Run-Check "Family index freshness (analyzers/README.md)" {
    Push-Location $repoRoot
    try {
      & (Join-Path $schemasDir "list-families.ps1") -WriteReadme | Out-Null
      $diff = git status --porcelain -- "analyzers/README.md" 2>$null
      if ($LASTEXITCODE -ne 0) {
        Write-Host "  (not a git repo or git unavailable - skipping staleness check, index was regenerated)"
        $global:LASTEXITCODE = 0
        return
      }
      if ($diff) {
        Write-Host "  analyzers/README.md is stale - regenerated it. Review and commit the change:"
        Write-Host "    git diff analyzers/README.md"
        $global:LASTEXITCODE = 1
      } else {
        $global:LASTEXITCODE = 0
      }
    }
    finally {
      Pop-Location
    }
  }
}

if ($failed) {
  Write-Host "One or more checks failed." -ForegroundColor Red
  exit 1
} else {
  Write-Host "All checks passed." -ForegroundColor Green
  exit 0
}
