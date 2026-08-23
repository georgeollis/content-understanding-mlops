<#
.SYNOPSIS
  Refreshes a family's derived golden-set artifacts in one step: expected.schema.json (from
  analyzer.json's fieldSchema) and manifest.json (checksums).

.DESCRIPTION
  Convenience wrapper around build-ground-truth-schema.ps1 + build-golden-manifest.ps1, which
  are almost always run together (whenever fieldSchema changes, or golden docs are
  added/removed/edited). Equivalent to running both manually:
    ./build-ground-truth-schema.ps1 -Family <family>
    ./build-golden-manifest.ps1 -Family <family>

.PARAMETER Family
  Analyzer family folder name, e.g. invoice.

.PARAMETER All
  Refresh every family under analyzers/.

.EXAMPLE
  ./update-golden.ps1 -Family invoice

.EXAMPLE
  ./update-golden.ps1 -All
#>
param(
  [string]$Family,
  [switch]$All
)

$ErrorActionPreference = "Stop"

if (-not $All -and -not $Family) {
  Write-Error "Provide -Family <name> or -All"
  exit 2
}

$commonArgs = if ($All) { @{ All = $true } } else { @{ Family = $Family } }

& (Join-Path $PSScriptRoot "build-ground-truth-schema.ps1") @commonArgs
& (Join-Path $PSScriptRoot "build-golden-manifest.ps1") @commonArgs
