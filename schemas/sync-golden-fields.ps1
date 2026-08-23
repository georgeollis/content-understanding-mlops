<#
.SYNOPSIS
  Patches every "<name>.expected.json" in a family's golden set to match its current
  analyzer.json fieldSchema, after a field has been added, removed, or renamed.

.DESCRIPTION
  Schema drift problem: if you add a field to analyzer.json's fieldSchema, existing
  expected.json files don't automatically get it - compare-analyzers.ps1 only scores fields
  that already exist in expected.json, so a newly added field would silently never be checked
  until someone remembers to hand-edit every golden document. validate-golden.ps1 now fails
  loudly when this happens; this script is the fix.

  For every "<name>.expected.json" under analyzers/<family>/golden/, this script:
    1. Adds any top-level field defined in expected.schema.json but missing from the file, as
       a deliberately wrong-typed placeholder ("<<FILL IN FROM PDF>>") - wrong-typed on purpose
       so validate-golden.ps1 keeps failing on that document until you replace the placeholder
       with a real value.
    2. Warns (does not delete) about any top-level field present in the file but no longer
       defined in the schema - could be an intentional rename in progress; you decide whether
       to fix the field name or remove it.

  This only inspects top-level fields. Adding/removing a *nested* property inside an existing
  object/array field is not auto-patched - edit those expected.json files directly.

.PARAMETER Family
  Analyzer family folder name, e.g. invoice. Run build-ground-truth-schema.ps1 first if
  fieldSchema changed, so expected.schema.json reflects the new shape.

.PARAMETER All
  Run for every family under analyzers/.

.EXAMPLE
  # After adding a new field to analyzers/invoice/analyzer.json's fieldSchema:
  .\build-ground-truth-schema.ps1 -Family invoice
  .\sync-golden-fields.ps1 -Family invoice
  # Then open each golden/*.expected.json and replace the "<<FILL IN FROM PDF>>" placeholders.

.NOTES
  Re-run build-golden-manifest.ps1 -Family <family> afterwards - the files' checksums changed.
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

# Builds a placeholder value shaped like the given schema node. Leaf scalars get a string
# placeholder deliberately - this is the wrong JSON type for number/integer/boolean/date
# fields, so validate-golden.ps1's type check keeps failing until a real value replaces it.
function New-Placeholder {
  param($SchemaNode)

  switch ($SchemaNode.type) {
    "array" {
      return @(New-Placeholder -SchemaNode $SchemaNode.items)
    }
    "object" {
      $obj = [ordered]@{}
      foreach ($propName in $SchemaNode.properties.PSObject.Properties.Name) {
        $obj[$propName] = New-Placeholder -SchemaNode $SchemaNode.properties.$propName
      }
      return $obj
    }
    default {
      return "<<FILL IN FROM PDF>>"
    }
  }
}

function Sync-Family {
  param([string]$FamilyName)

  $goldenDir = Join-Path $analyzersDir $FamilyName "golden"
  $schemaPath = Join-Path $goldenDir "expected.schema.json"
  if (-not (Test-Path $schemaPath)) {
    Write-Host "SKIP $FamilyName - no expected.schema.json (run build-ground-truth-schema.ps1 -Family $FamilyName first)"
    return
  }
  $gtSchema = Get-Content $schemaPath -Raw | ConvertFrom-Json
  $schemaFieldNames = @($gtSchema.properties.PSObject.Properties.Name)

  $expectedFiles = Get-ChildItem $goldenDir -Filter "*.expected.json"
  if ($expectedFiles.Count -eq 0) {
    Write-Host "SKIP $FamilyName - no *.expected.json files in golden/"
    return
  }

  foreach ($file in $expectedFiles) {
    $data = Get-Content $file.FullName -Raw | ConvertFrom-Json
    $existingNames = @($data.PSObject.Properties.Name)

    $added = @()
    foreach ($fieldName in ($schemaFieldNames | Where-Object { $existingNames -notcontains $_ })) {
      $data | Add-Member -NotePropertyName $fieldName -NotePropertyValue (New-Placeholder -SchemaNode $gtSchema.properties.$fieldName)
      $added += $fieldName
    }

    $extra = @($existingNames | Where-Object { $_ -ne "_bootstrap" -and $schemaFieldNames -notcontains $_ })

    if ($added.Count -gt 0) {
      $data | ConvertTo-Json -Depth 20 | Set-Content -Path $file.FullName -Encoding utf8
      Write-Host "PATCHED $($file.Name): added placeholder(s) for $($added -join ', ')" -ForegroundColor Yellow
    }
    if ($extra.Count -gt 0) {
      Write-Host "WARN    $($file.Name): field(s) $($extra -join ', ') not in current fieldSchema - fix the name or remove them by hand" -ForegroundColor DarkYellow
    }
    if ($added.Count -eq 0 -and $extra.Count -eq 0) {
      Write-Host "OK      $($file.Name): already matches fieldSchema"
    }
  }
}

$families = if ($All) { Get-AllFamilies } else { @($Family) }

foreach ($f in $families) {
  Sync-Family -FamilyName $f
}

Write-Host ""
Write-Host "Re-run 'pwsh -File ./schemas/build-golden-manifest.ps1 -Family <family>' for any family with patched files (checksums changed)." -ForegroundColor Cyan
