<#
.SYNOPSIS
  Builds a standalone, self-contained JSON Schema for Content Understanding analyzer
  definitions, extracted from the official Swagger/OpenAPI spec published in
  Azure/azure-rest-api-specs.

.DESCRIPTION
  Source:
    specification/ai/data-plane/ContentUnderstanding/stable/2025-11-01/ContentUnderstanding.json
    (Swagger 2.0, generated from the TypeSpec source of truth)

  Reads:  $env:TEMP\ContentUnderstanding.swagger.json  (auto-downloaded if missing)
  Writes: schemas/analyzer.schema.json

.EXAMPLE
  .\build-analyzer-schema.ps1
#>

$ErrorActionPreference = "Stop"

$swaggerPath = Join-Path $env:TEMP "ContentUnderstanding.swagger.json"
$outputPath = Join-Path $PSScriptRoot "analyzer.schema.json"
$swaggerUrl = "https://raw.githubusercontent.com/Azure/azure-rest-api-specs/main/specification/ai/data-plane/ContentUnderstanding/stable/2025-11-01/ContentUnderstanding.json"
$rootDefinition = "ContentAnalyzer"

# Properties that only make sense on the server-returned resource (readOnly / computed),
# not on the local analyzer JSON files we author and PUT to the service.
$readOnlyPropsToDrop = @("analyzerId", "status", "createdAt", "lastModifiedAt", "warnings", "supportedModels")

if (-not (Test-Path $swaggerPath)) {
  Write-Host "Downloading swagger spec from $swaggerUrl ..."
  Invoke-WebRequest -Uri $swaggerUrl -OutFile $swaggerPath
  Write-Host "Saved to $swaggerPath"
}

$swagger = Get-Content $swaggerPath -Raw | ConvertFrom-Json
$defs = $swagger.definitions

function Get-Refs {
  param($Node, $Defs, [System.Collections.Generic.HashSet[string]]$Collected)

  if ($Node -is [System.Management.Automation.PSCustomObject]) {
    foreach ($prop in $Node.PSObject.Properties) {
      if ($prop.Name -eq '$ref' -and $prop.Value -is [string] -and $prop.Value.StartsWith("#/definitions/")) {
        $name = $prop.Value.Split("/")[-1]
        if ($Collected.Add($name) -and $Defs.PSObject.Properties.Name -contains $name) {
          Get-Refs -Node $Defs.$name -Defs $Defs -Collected $Collected
        }
      } else {
        Get-Refs -Node $prop.Value -Defs $Defs -Collected $Collected
      }
    }
  }
  elseif ($Node -is [System.Array]) {
    foreach ($item in $Node) { Get-Refs -Node $item -Defs $Defs -Collected $Collected }
  }
}

$root = $defs.$rootDefinition
$collected = [System.Collections.Generic.HashSet[string]]::new()
$collected.Add($rootDefinition) | Out-Null
Get-Refs -Node $root -Defs $defs -Collected $collected

$sortedNames = $collected | Sort-Object
$outDefs = [ordered]@{}
foreach ($name in $sortedNames) { $outDefs[$name] = $defs.$name }

# Trim server-only fields from the root so authors aren't tempted to set them locally.
$rootCopy = $outDefs[$rootDefinition] | ConvertTo-Json -Depth 50 | ConvertFrom-Json
if ($rootCopy.properties) {
  foreach ($prop in $readOnlyPropsToDrop) {
    if ($rootCopy.properties.PSObject.Properties.Name -contains $prop) {
      $rootCopy.properties.PSObject.Properties.Remove($prop)
    }
  }
}
if ($rootCopy.required) {
  $rootCopy.required = @($rootCopy.required | Where-Object { $readOnlyPropsToDrop -notcontains $_ })
}
$outDefs[$rootDefinition] = $rootCopy

$schema = [ordered]@{
  '$schema'   = "http://json-schema.org/draft-04/schema#"
  title       = "ContentAnalyzer (local authoring schema)"
  description = "Schema for locally-authored Content Understanding analyzer definitions (the PUT /analyzers/{analyzerId} request body). Extracted from the official Azure REST API spec for api-version 2025-11-01 (GA). Source: https://github.com/Azure/azure-rest-api-specs/blob/main/specification/ai/data-plane/ContentUnderstanding/stable/2025-11-01/ContentUnderstanding.json"
  '$ref'      = "#/definitions/$rootDefinition"
  definitions = $outDefs
}

($schema | ConvertTo-Json -Depth 50) | Set-Content -Path $outputPath -Encoding utf8

Write-Host "Wrote $outputPath with $($sortedNames.Count) definitions: $($sortedNames -join ', ')"
