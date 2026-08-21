<#
.SYNOPSIS
  Prints (and can rewrite into analyzers/README.md) a summary index of every analyzer family.

.DESCRIPTION
  Summarizes each family's description, currently-live analyzerId, and golden document count.

.PARAMETER WriteReadme
  Also update the table in analyzers/README.md (between the `<!-- Regenerate this table with:
  ... -->` marker and the next blank line).

.EXAMPLE
  .\list-families.ps1

.EXAMPLE
  .\list-families.ps1 -WriteReadme
#>
param(
  [switch]$WriteReadme
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$analyzersDir = Join-Path $repoRoot "analyzers"
$readmePath = Join-Path $analyzersDir "README.md"

$tableStart = "<!-- Regenerate this table with: pwsh -File schemas/list-families.ps1 -WriteReadme -->"

function Get-Rows {
  $rows = @()
  Get-ChildItem $analyzersDir -Directory | Sort-Object Name | ForEach-Object {
    $familyDir = $_.FullName
    $family = $_.Name
    $manifestPath = Join-Path $familyDir "manifest.json"
    if (-not (Test-Path $manifestPath)) { return }

    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $current = if ($manifest.current) { $manifest.current } else { "_(not deployed)_" }

    $goldenManifestPath = Join-Path $familyDir "golden\manifest.json"
    $goldenCount = "0"
    if (Test-Path $goldenManifestPath) {
      $goldenManifest = Get-Content $goldenManifestPath -Raw | ConvertFrom-Json
      $goldenCount = "$($goldenManifest.documentCount)"
    }

    $rows += [PSCustomObject]@{
      Family      = $family
      Description = $manifest.description
      Current     = $current
      GoldenCount = $goldenCount
    }
  }
  return $rows
}

function Format-Table {
  param($Rows)
  $lines = @("| Family | Description | Current (live) | Golden docs |", "|---|---|---|---|")
  foreach ($r in $Rows) {
    $lines += "| ``$($r.Family)`` | $($r.Description) | ``$($r.Current)`` | $($r.GoldenCount) |"
  }
  return ($lines -join "`n")
}

$rows = Get-Rows
$table = Format-Table -Rows $rows
Write-Host $table

if ($WriteReadme) {
  $content = Get-Content $readmePath -Raw

  $pattern = [regex]::Escape($tableStart) + "\r?\n\r?\n(\|.*\r?\n)+"
  $replacement = "$tableStart`n`n$table`n"

  if (-not [regex]::IsMatch($content, $pattern)) {
    throw "Could not find table marker in $readmePath"
  }

  $newContent = [regex]::Replace($content, $pattern, { param($m) $replacement })
  Set-Content -Path $readmePath -Value $newContent -Encoding utf8 -NoNewline
  Write-Host ""
  Write-Host "Updated $readmePath"
}
