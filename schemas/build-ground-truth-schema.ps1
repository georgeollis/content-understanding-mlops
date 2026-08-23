<#
.SYNOPSIS
  Builds a JSON Schema for a family's ground-truth "*.expected.json" files, derived directly
  from that family's analyzer.json fieldSchema.

.DESCRIPTION
  Deriving the schema (rather than hand-writing it) means a typo'd or renamed field in
  expected.json fails loudly instead of silently scoring as "missing" in compare-analyzers.ps1.

.PARAMETER Family
  Analyzer family folder name, e.g. invoice.

.PARAMETER All
  Build for every family under analyzers/.

.EXAMPLE
  .\build-ground-truth-schema.ps1 -Family invoice

.EXAMPLE
  .\build-ground-truth-schema.ps1 -All

.NOTES
  Writes: analyzers/<family>/golden/expected.schema.json
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

# Maps Content Understanding ContentFieldType -> JSON Schema type for ground-truth values.
# date/time are represented as plain strings in our expected.json ground truth (ISO date strings).
$simpleTypeMap = @{
  "string"  = "string"
  "date"    = "string"
  "time"    = "string"
  "number"  = "number"
  "integer" = "integer"
  "boolean" = "boolean"
}

function Convert-FieldDefToSchema {
  param($FieldDef)

  $ftype = $FieldDef.type
  $description = $FieldDef.description

  if ($simpleTypeMap.ContainsKey($ftype)) {
    $schema = [ordered]@{ type = $simpleTypeMap[$ftype] }
  }
  elseif ($ftype -eq "array") {
    $itemsDef = if ($FieldDef.items) { $FieldDef.items } else { [PSCustomObject]@{} }
    $schema = [ordered]@{ type = "array"; items = (Convert-FieldDefToSchema -FieldDef $itemsDef) }
  }
  elseif ($ftype -eq "object") {
    $props = if ($FieldDef.properties) { $FieldDef.properties.PSObject.Properties } else { @() }
    $propsSchema = [ordered]@{}
    foreach ($p in $props) { $propsSchema[$p.Name] = Convert-FieldDefToSchema -FieldDef $p.Value }
    $schema = [ordered]@{
      type       = "object"
      properties = $propsSchema
      required   = @($props | ForEach-Object { $_.Name })
    }
  }
  else {
    $schema = [ordered]@{}
  }

  if ($description) { $schema["description"] = $description }
  return $schema
}

function Build-SchemaForFamily {
  param([string]$FamilyName)

  $analyzerPath = Join-Path $analyzersDir $FamilyName "analyzer.json"
  if (-not (Test-Path $analyzerPath)) {
    throw "No analyzer.json found for family '$FamilyName' at $analyzerPath"
  }

  $analyzer = Get-Content $analyzerPath -Raw | ConvertFrom-Json
  $fields = if ($analyzer.fieldSchema -and $analyzer.fieldSchema.fields) { $analyzer.fieldSchema.fields.PSObject.Properties } else { @() }

  $properties = [ordered]@{}
  foreach ($f in $fields) { $properties[$f.Name] = Convert-FieldDefToSchema -FieldDef $f.Value }

  $schema = [ordered]@{
    '$schema'    = "http://json-schema.org/draft-04/schema#"
    title        = "$FamilyName ground-truth (expected.json) schema"
    description  = "Auto-generated from analyzers/$FamilyName/analyzer.json. Do not hand-edit; re-run build-ground-truth-schema.ps1 after changing the analyzer's fieldSchema."
    type         = "object"
    properties   = $properties
    required     = @($properties.Keys)
    additionalProperties = $false
  }

  $goldenDir = Join-Path $analyzersDir $FamilyName "golden"
  New-Item -ItemType Directory -Force -Path $goldenDir | Out-Null
  $outPath = Join-Path $goldenDir "expected.schema.json"
  ($schema | ConvertTo-Json -Depth 20) | Set-Content -Path $outPath -Encoding utf8

  Write-Host "Wrote $outPath ($($properties.Keys.Count) fields)"
  return $outPath
}

function Get-AllFamilies {
  Get-ChildItem $analyzersDir -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName "analyzer.json") } |
    ForEach-Object { $_.Name } |
    Sort-Object
}

$families = if ($All) { Get-AllFamilies } else { @($Family) }

foreach ($f in $families) {
  Build-SchemaForFamily -FamilyName $f | Out-Null
}
