<#
.SYNOPSIS
  Validates a family's golden test-data set (checksums + ground-truth schema conformance).

.DESCRIPTION
  Checks, per family:
    1. Every "<name>.expected.json" conforms to analyzers/<family>/golden/expected.schema.json
       (auto-derived from analyzer.json's fieldSchema - catches typo'd/renamed fields).
    2. Every file's sha256 matches analyzers/<family>/golden/manifest.json (catches silent
       edits, corruption, or the manifest being stale after someone changed a golden doc).
    3. manifest.json's document list matches what's actually on disk (catches added/removed
       docs that the manifest wasn't regenerated for).
    4. Every field currently in analyzer.json's fieldSchema is present in each
       "<name>.expected.json" (catches schema drift - a field added after the golden set was
       built would otherwise silently never be scored) - run sync-golden-fields.ps1 to patch.
    5. No "<name>.expected.json" still has an unreviewed "_bootstrap" marker left by
       bootstrap-golden.ps1, and no field exists that analyzer.json's fieldSchema no longer
       defines (a rename/removal that expected.json wasn't updated for).

.PARAMETER Family
  Validate only this family, e.g. invoice.

.PARAMETER All
  Validate every family under analyzers/.

.EXAMPLE
  .\validate-golden.ps1 -Family invoice

.EXAMPLE
  .\validate-golden.ps1 -All

.NOTES
  Exit code is non-zero if any check fails (usable as a CI gate / pre-commit hook).
  If you've intentionally added/removed/edited golden docs, re-run:
    .\build-golden-manifest.ps1 -Family <family>
    .\build-ground-truth-schema.ps1 -Family <family>   (only needed if the analyzer's fields changed)
#>
param(
  [string]$Family,
  [switch]$All
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$analyzersDir = Join-Path $repoRoot "analyzers"

if (-not $All -and -not $Family) {
  Write-Error "Provide -Family <name> or -All"
  exit 2
}

function Get-AllFamilies {
  Get-ChildItem $analyzersDir -Directory |
    Where-Object { $_.Name -notlike "_*" } |
    Where-Object { Test-Path (Join-Path $_.FullName "golden") } |
    ForEach-Object { $_.Name } |
    Sort-Object
}

function Get-Sha256 {
  param([string]$Path)
  (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
}

# Minimal recursive check that a JSON value's shape matches the derived expected.schema.json
# (types only - this mirrors the level of checking build-ground-truth-schema.ps1 produces).
function Test-ExpectedAgainstSchema {
  param($Value, $Schema, [string]$Path, [ref]$Errors)

  $type = $Schema.type
  if (-not $type) { return }

  switch ($type) {
    "object" {
      if ($null -eq $Value -or $Value -isnot [System.Management.Automation.PSCustomObject]) {
        $Errors.Value += "${Path}: expected object"
        return
      }
      foreach ($propName in $Schema.properties.PSObject.Properties.Name) {
        $childSchema = $Schema.properties.$propName
        $childValue = $Value.$propName
        Test-ExpectedAgainstSchema -Value $childValue -Schema $childSchema -Path "$Path.$propName" -Errors $Errors
      }
    }
    "array" {
      if ($Value -isnot [System.Array] -and $Value -isnot [System.Collections.IEnumerable]) {
        $Errors.Value += "${Path}: expected array"
        return
      }
      $i = 0
      foreach ($item in $Value) {
        Test-ExpectedAgainstSchema -Value $item -Schema $Schema.items -Path "$Path[$i]" -Errors $Errors
        $i++
      }
    }
    "number" {
      if ($null -ne $Value -and -not ($Value -is [double] -or $Value -is [int] -or $Value -is [long])) {
        $Errors.Value += "${Path}: expected number"
      }
    }
    "integer" {
      if ($null -ne $Value -and -not ($Value -is [int] -or $Value -is [long])) {
        $Errors.Value += "${Path}: expected integer"
      }
    }
    "boolean" {
      if ($null -ne $Value -and $Value -isnot [bool]) {
        $Errors.Value += "${Path}: expected boolean"
      }
    }
    "string" {
      if ($null -ne $Value -and $Value -isnot [string]) {
        $Errors.Value += "${Path}: expected string"
      }
    }
  }
}

function Test-GoldenFamily {
  param([string]$FamilyName)

  $goldenDir = Join-Path $analyzersDir "$FamilyName\golden"
  $manifestPath = Join-Path $goldenDir "manifest.json"
  $schemaPath = Join-Path $goldenDir "expected.schema.json"
  $errors = @()

  if (-not (Test-Path $manifestPath)) {
    return @("Missing $manifestPath - run build-golden-manifest.ps1 -Family $FamilyName")
  }
  if (-not (Test-Path $schemaPath)) {
    return @("Missing $schemaPath - run build-ground-truth-schema.ps1 -Family $FamilyName")
  }

  $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
  $gtSchema = Get-Content $schemaPath -Raw | ConvertFrom-Json

  $manifestNames = @($manifest.documents | ForEach-Object { $_.name })
  $diskNames = @(Get-ChildItem $goldenDir -Filter "*.pdf" | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) })

  foreach ($missing in ($diskNames | Where-Object { $manifestNames -notcontains $_ })) {
    $errors += "${missing}: on disk but not in manifest.json - re-run build-golden-manifest.ps1 -Family $FamilyName"
  }
  foreach ($stale in ($manifestNames | Where-Object { $diskNames -notcontains $_ })) {
    $errors += "${stale}: in manifest.json but PDF missing on disk"
  }

  foreach ($doc in $manifest.documents) {
    $name = $doc.name
    $pdfPath = Join-Path $goldenDir $doc.pdf
    $expectedPath = Join-Path $goldenDir $doc.expected

    if (-not (Test-Path $pdfPath)) { $errors += "${name}: $($doc.pdf) not found"; continue }
    if (-not (Test-Path $expectedPath)) { $errors += "${name}: $($doc.expected) not found"; continue }

    $actualPdfSha = Get-Sha256 -Path $pdfPath
    if ($actualPdfSha -ne $doc.pdfSha256) {
      $errors += "${name}: $($doc.pdf) checksum mismatch (file changed since manifest was built)"
    }

    $actualExpectedSha = Get-Sha256 -Path $expectedPath
    if ($actualExpectedSha -ne $doc.expectedSha256) {
      $errors += "${name}: $($doc.expected) checksum mismatch (file changed since manifest was built)"
    }

    $expectedData = Get-Content $expectedPath -Raw | ConvertFrom-Json

    $actualFieldNames = @($expectedData.PSObject.Properties.Name)
    $schemaFieldNames = @($gtSchema.properties.PSObject.Properties.Name)

    if ($actualFieldNames -contains "_bootstrap") {
      $errors += "${name}: $($doc.expected) still has an unreviewed '_bootstrap' marker - review the values against the PDF, then delete that key"
    }

    foreach ($missingField in ($schemaFieldNames | Where-Object { $actualFieldNames -notcontains $_ })) {
      $errors += "${name}: $($doc.expected) is missing field '$missingField' (present in analyzer.json's fieldSchema) - run 'schemas/sync-golden-fields.ps1 -Family $FamilyName' to add a placeholder, then fill in the real value"
    }
    foreach ($extraField in ($actualFieldNames | Where-Object { $_ -ne "_bootstrap" -and $schemaFieldNames -notcontains $_ })) {
      $errors += "${name}: $($doc.expected) has field '$extraField' not found in analyzer.json's fieldSchema (renamed or removed?) - fix the field name or remove it"
    }

    $schemaErrors = @()
    Test-ExpectedAgainstSchema -Value $expectedData -Schema $gtSchema -Path $doc.expected -Errors ([ref]$schemaErrors)
    foreach ($e in $schemaErrors) { $errors += "${name}: $e" }
  }

  return $errors
}

$families = if ($All) { Get-AllFamilies } else { @($Family) }

$hadErrors = $false
foreach ($f in $families) {
  $errors = Test-GoldenFamily -FamilyName $f
  if ($errors.Count -gt 0) {
    $hadErrors = $true
    Write-Host "FAIL $f/golden: $($errors.Count) issue(s)"
    foreach ($e in $errors) { Write-Host "  - $e" }
  } else {
    Write-Host "OK   $f/golden"
  }
}

exit ($(if ($hadErrors) { 1 } else { 0 }))
