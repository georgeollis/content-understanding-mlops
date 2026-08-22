<#
.SYNOPSIS
  Validates every analyzers/<family>/analyzer.json against schemas/analyzer.schema.json.

.DESCRIPTION
  Checks each field definition's "type" is one of the allowed Content Understanding field
  types, "method" is a valid generation method, "processingLocation" is valid, and
  "baseAnalyzerId" (if set) matches the allowed pattern. Nested array/object fields are
  checked recursively.

.PARAMETER Family
  Validate only this family; omit to validate all.

.EXAMPLE
  .\validate-analyzers.ps1

.EXAMPLE
  .\validate-analyzers.ps1 -Family invoice

.NOTES
  Exit code is non-zero if any file fails validation (usable as a CI gate / pre-commit hook).
#>
param(
  [string]$Family
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$analyzersDir = Join-Path $repoRoot "analyzers"

$allowedFieldTypes = @("string", "date", "time", "number", "integer", "boolean", "array", "object", "json")
$allowedMethods = @("extract", "classify", "generate")
$allowedProcessingLocations = @("geography", "dataZone", "global")
$baseAnalyzerIdPattern = "^[a-zA-Z0-9._-]{1,64}$"

function Get-AllFamilies {
  Get-ChildItem $analyzersDir -Directory |
    Where-Object { $_.Name -notlike "_*" } |
    Where-Object { Test-Path (Join-Path $_.FullName "analyzer.json") } |
    ForEach-Object { $_.Name } |
    Sort-Object
}

function Test-FieldDef {
  param($FieldDef, [string]$Path, [ref]$Errors)

  $type = $FieldDef.type
  if (-not $type) {
    $Errors.Value += "${Path}: missing 'type'"
    return
  }
  if ($allowedFieldTypes -notcontains $type) {
    $Errors.Value += "${Path}: invalid type '$type' (expected one of: $($allowedFieldTypes -join ', '))"
    return
  }

  if ($type -eq "array" -and $FieldDef.items) {
    Test-FieldDef -FieldDef $FieldDef.items -Path "$Path.items" -Errors $Errors
  }
  if ($type -eq "object" -and $FieldDef.properties) {
    foreach ($prop in $FieldDef.properties.PSObject.Properties) {
      Test-FieldDef -FieldDef $prop.Value -Path "$Path.properties.$($prop.Name)" -Errors $Errors
    }
  }
}

function Test-Analyzer {
  param([string]$FamilyName)

  $path = Join-Path $analyzersDir "$FamilyName\analyzer.json"
  $data = Get-Content $path -Raw | ConvertFrom-Json
  $errors = @()

  if ($data.baseAnalyzerId -and $data.baseAnalyzerId -notmatch $baseAnalyzerIdPattern) {
    $errors += "baseAnalyzerId '$($data.baseAnalyzerId)' does not match pattern $baseAnalyzerIdPattern"
  }

  if ($data.fieldSchema -and $data.fieldSchema.fields) {
    foreach ($field in $data.fieldSchema.fields.PSObject.Properties) {
      Test-FieldDef -FieldDef $field.Value -Path "fieldSchema.fields.$($field.Name)" -Errors ([ref]$errors)
      if ($field.Value.method -and $allowedMethods -notcontains $field.Value.method) {
        $errors += "fieldSchema.fields.$($field.Name): invalid method '$($field.Value.method)' (expected one of: $($allowedMethods -join ', '))"
      }
    }
  }

  if ($data.config -and $data.config.processingLocation) {
    if ($allowedProcessingLocations -notcontains $data.config.processingLocation) {
      $errors += "config.processingLocation: invalid value '$($data.config.processingLocation)' (expected one of: $($allowedProcessingLocations -join ', '))"
    }
  }

  if ($errors.Count -gt 0) {
    Write-Host "FAIL $FamilyName/analyzer.json: $($errors.Count) error(s)"
    foreach ($e in $errors) { Write-Host "  - $e" }
    return $false
  } else {
    Write-Host "OK   $FamilyName/analyzer.json"
    return $true
  }
}

$families = if ($Family) { @($Family) } else { Get-AllFamilies }

$hadErrors = $false
foreach ($f in $families) {
  if (-not (Test-Analyzer -FamilyName $f)) { $hadErrors = $true }
}

exit ($(if ($hadErrors) { 1 } else { 0 }))
