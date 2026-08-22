<#
.SYNOPSIS
  Prints (and can rewrite into analyzers/README.md) a summary index of every analyzer family,
  showing what's currently live in each environment.

.DESCRIPTION
  Each family folder can have one manifest.<environment>.json per environment (e.g.
  manifest.dev.json, manifest.test.json, manifest.prod.json). This summarizes each family's
  description, golden document count, and currently-live analyzerId per environment found.

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

    $manifestFiles = Get-ChildItem $familyDir -Filter "manifest.*.json" -ErrorAction SilentlyContinue
    if (-not $manifestFiles -or $manifestFiles.Count -eq 0) { return }

    $description = $null
    $envStatus = [ordered]@{}
    foreach ($mf in ($manifestFiles | Sort-Object Name)) {
      # manifest.<env>.json -> <env>
      $envName = $mf.Name -replace '^manifest\.', '' -replace '\.json$', ''
      $manifest = Get-Content $mf.FullName -Raw | ConvertFrom-Json
      if (-not $description) { $description = $manifest.description }
      $envStatus[$envName] = if ($manifest.current) { $manifest.current } else { "_(not deployed)_" }
    }

    $goldenManifestPath = Join-Path $familyDir "golden\manifest.json"
    $goldenCount = "0"
    if (Test-Path $goldenManifestPath) {
      $goldenManifest = Get-Content $goldenManifestPath -Raw | ConvertFrom-Json
      $goldenCount = "$($goldenManifest.documentCount)"
    }

    $envSummary = ($envStatus.Keys | ForEach-Object { "$_`: ``$($envStatus[$_])``" }) -join "; "

    $rows += [PSCustomObject]@{
      Family      = $family
      Description = $description
      EnvSummary  = $envSummary
      GoldenCount = $goldenCount
    }
  }
  return $rows
}

function Format-Table {
  param($Rows)
  $lines = @("| Family | Description | Current (by environment) | Golden docs |", "|---|---|---|---|")
  foreach ($r in $Rows) {
    $lines += "| ``$($r.Family)`` | $($r.Description) | $($r.EnvSummary) | $($r.GoldenCount) |"
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
