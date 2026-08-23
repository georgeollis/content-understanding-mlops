<#
.SYNOPSIS
  Runs a golden test-data set of documents through one or more Content Understanding analyzers
  and compares extracted fields against ground truth (and against each other).

.DESCRIPTION
  For every "<name>.pdf" + "<name>.expected.json" pair found in -GoldenDir, this script:
    1. Submits the PDF to each analyzer in -AnalyzerIds via POST .../analyzers/{id}:analyzeBinary
    2. Polls the operation until the result is ready
    3. Flattens the extracted ContentField result into plain values (and, if the analyzer's
       config has "estimateFieldSourceAndConfidence": true, per-field confidence scores 0-1)
    4. Compares each field against the expected.json ground truth (numeric tolerance, case/whitespace
       insensitive string matching, and item-by-item comparison for array fields like LineItems)
    5. Prints a per-document, per-analyzer match report (including confidence, when available)
       plus an overall accuracy summary with average confidence, so you can see
       regressions/improvements when comparing two versions of the same analyzer (e.g.
       invoicev1 vs invoicev2).

  Confidence scores are only returned by the API when the analyzer definition
  (analyzers/<family>/analyzer.json) has "config": { "estimateFieldSourceAndConfidence": true }.
  If that's not set, confidence is reported as "n/a" and excluded from the average. This is
  top-level fields only - nested confidence inside array/object field items (e.g. per-line-item
  confidence on a LineItems array) is not currently extracted.

  Authentication uses a Microsoft Entra ID access token (az account get-access-token).

.PARAMETER Environment
  Environment name (e.g. "dev", "test", "prod") as defined in environments.json at the repo
  root. Resolves -Endpoint automatically. Either -Environment or -Endpoint is required.

.PARAMETER Endpoint
  The Content Understanding resource endpoint, e.g. https://myresource.cognitiveservices.azure.com
  Overrides whatever -Environment would have resolved to.

.PARAMETER AnalyzerIds
  One or more analyzer IDs to run against the golden set (e.g. "invoicev1", "invoicev2").

.PARAMETER Family
  Analyzer family folder name under analyzers/, e.g. "invoice" or "complaint".
  Resolves -GoldenDir to "analyzers/<Family>/golden" automatically. Ignored if -GoldenDir is
  also supplied explicitly.

.PARAMETER GoldenDir
  Folder containing "<name>.pdf" + "<name>.expected.json" pairs. If omitted, resolved from
  -Family (analyzers/<Family>/golden); if neither is supplied, defaults to
  "..\analyzers\invoice\golden" relative to this script for backward compatibility.

.PARAMETER ApiVersion
  Content Understanding API version. Defaults to the current GA version.

.PARAMETER SaveResults
  If set (default), writes a structured JSON report of this comparison run to
  "analyzers/<Family>/results/<timestamp>_<analyzerIds>.json" so accuracy trends over time
  can be tracked and diffed in git. Requires -Family (results are stored per-family). Pass
  -SaveResults:$false to skip.

.PARAMETER ResultsDir
  Override the folder results are saved to. Defaults to "analyzers/<Family>/results".

.EXAMPLE
  # Compare two versions of the invoice analyzer against the golden invoice set
  .\compare-analyzers.ps1 -Environment dev -Family invoice -AnalyzerIds "invoicev1", "invoicev2"
#>
param(
  [string]$Environment,

  [string]$Endpoint,

  [Parameter(Mandatory = $true)]
  [string[]]$AnalyzerIds,

  [string]$Family,

  [string]$GoldenDir,

  [string]$ApiVersion = "2025-11-01",

  [bool]$SaveResults = $true,

  [string]$ResultsDir
)

$ErrorActionPreference = "Stop"

# ---------- Resolve endpoint ----------
if (-not $Environment -and -not $Endpoint) {
  throw "Provide -Environment <name> (see environments.json) or -Endpoint <url>."
}
if (-not $Endpoint) {
  $repoRootForEnv = Resolve-Path (Join-Path $PSScriptRoot "..")
  $envConfigPath = Join-Path $repoRootForEnv "environments.json"
  if (-not (Test-Path $envConfigPath)) { throw "Not found: $envConfigPath. Create it or pass -Endpoint directly." }
  $envConfig = Get-Content $envConfigPath -Raw | ConvertFrom-Json
  $envEntry = $envConfig.environments.$Environment
  if (-not $envEntry) { throw "Environment '$Environment' not found in $envConfigPath. Add it, or pass -Endpoint directly." }
  $Endpoint = $envEntry.endpoint
}
if (-not $Environment) { $Environment = "default" }

# ---------- Resolve golden directory ----------
if (-not $GoldenDir) {
  if ($Family) {
    $GoldenDir = Join-Path $PSScriptRoot "..\analyzers\$Family\golden"
  } else {
    $GoldenDir = Join-Path $PSScriptRoot "..\analyzers\invoice\golden"
    Write-Warning "No -Family or -GoldenDir supplied; defaulting to '$GoldenDir'. Pass -Family <name> to target a different analyzer family."
  }
}
if (-not (Test-Path $GoldenDir)) { throw "Golden directory not found: $GoldenDir" }

$token = az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv
if (-not $token) { throw "Failed to acquire access token. Run 'az login' first." }
$endpointTrimmed = $Endpoint.TrimEnd('/')

# ---------- Helpers ----------

# Recursively converts a raw ContentField ({type, valueString|valueNumber|valueArray|...}) into a plain value.
function ConvertFrom-ContentField {
  param($field)
  if ($null -eq $field) { return $null }
  switch ($field.type) {
    "string"  { return $field.valueString }
    "date"    { return $field.valueDate }
    "time"    { return $field.valueTime }
    "number"  { return $field.valueNumber }
    "integer" { return $field.valueInteger }
    "boolean" { return $field.valueBoolean }
    "array"   { return @($field.valueArray | ForEach-Object { ConvertFrom-ContentField $_ }) }
    "object"  {
      $obj = [ordered]@{}
      if ($field.valueObject) {
        foreach ($p in $field.valueObject.PSObject.Properties) {
          $obj[$p.Name] = ConvertFrom-ContentField $p.Value
        }
      }
      return $obj
    }
    "json"    { return $field.valueJson }
    default   { return $null }
  }
}

# Flattens the analyzer's raw "fields" object into a simple name -> plain value map.
function Get-FlatFields {
  param($fieldsObject)
  $flat = [ordered]@{}
  if ($fieldsObject) {
    foreach ($p in $fieldsObject.PSObject.Properties) {
      $flat[$p.Name] = ConvertFrom-ContentField $p.Value
    }
  }
  return $flat
}

# Flattens the analyzer's raw "fields" object into a name -> confidence (0-1, or $null) map.
# Only present when the analyzer's config has "estimateFieldSourceAndConfidence": true (or the
# field itself has "estimateSourceAndConfidence": true in fieldSchema) - otherwise every field's
# "confidence" property is absent and this returns $null for all of them.
# NOTE: top-level only, same limitation as Get-FlatFields - nested confidence inside array/object
# field items (e.g. per-line-item confidence on LineItems) is not extracted here.
function Get-FlatConfidences {
  param($fieldsObject)
  $flat = [ordered]@{}
  if ($fieldsObject) {
    foreach ($p in $fieldsObject.PSObject.Properties) {
      $flat[$p.Name] = if ($null -ne $p.Value.confidence) { [double]$p.Value.confidence } else { $null }
    }
  }
  return $flat
}

function Normalize-StringValue {
  param($v)
  if ($null -eq $v) { return "" }
  return ([string]$v).Trim().ToLowerInvariant()
}

# Compares an expected value to an actual value with tolerance for numbers/strings/arrays of objects.
function Test-ValueMatch {
  param($expected, $actual)

  if ($null -eq $expected -and $null -eq $actual) { return $true }
  if ($null -eq $expected -or $null -eq $actual) { return $false }

  if ($expected -is [System.Collections.IEnumerable] -and $expected -isnot [string]) {
    $expectedArr = @($expected)
    $actualArr = @($actual)
    if ($expectedArr.Count -ne $actualArr.Count) { return $false }
    for ($i = 0; $i -lt $expectedArr.Count; $i++) {
      $e = $expectedArr[$i]
      $a = $actualArr[$i]
      if ($e -is [System.Collections.Specialized.OrderedDictionary] -or $e.PSObject.Properties.Count -gt 0 -and $e -isnot [string]) {
        foreach ($key in $e.PSObject.Properties.Name) {
          $av = if ($a -is [System.Collections.Specialized.OrderedDictionary]) { $a[$key] } else { $a.$key }
          if (-not (Test-ValueMatch $e.$key $av)) { return $false }
        }
      } elseif (-not (Test-ValueMatch $e $a)) {
        return $false
      }
    }
    return $true
  }

  $isNumeric = { param($v) $v -is [double] -or $v -is [int] -or $v -is [long] -or $v -is [decimal] }
  if ((& $isNumeric $expected) -and (& $isNumeric $actual)) {
    return [Math]::Abs([double]$expected - [double]$actual) -lt 0.01
  }

  return (Normalize-StringValue $expected) -eq (Normalize-StringValue $actual)
}

function Invoke-AnalyzeBinary {
  param([string]$AnalyzerId, [string]$FilePath)

  $bytes = [System.IO.File]::ReadAllBytes($FilePath)
  $headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/pdf" }
  $uri = "$endpointTrimmed/contentunderstanding/analyzers/$AnalyzerId`:analyzeBinary?api-version=$ApiVersion"

  $response = Invoke-WebRequest -Uri $uri -Headers $headers -Method POST -Body $bytes
  $opLocation = $response.Headers['Operation-Location'][0]

  $getHeaders = @{ Authorization = "Bearer $token" }
  do {
    Start-Sleep -Seconds 2
    $op = Invoke-RestMethod -Uri $opLocation -Headers $getHeaders -Method GET
  } while ($op.status -eq "NotStarted" -or $op.status -eq "Running")

  if ($op.status -ne "Succeeded") {
    throw "Analyze failed for '$AnalyzerId' on '$FilePath': $($op.error | ConvertTo-Json -Depth 5)"
  }

  $fieldsRaw = $op.result.contents[0].fields
  return [ordered]@{
    values      = Get-FlatFields $fieldsRaw
    confidences = Get-FlatConfidences $fieldsRaw
  }
}

# ---------- Discover golden set ----------
if (-not (Test-Path $GoldenDir)) { throw "Golden data folder not found: $GoldenDir" }
$goldenPdfs = Get-ChildItem $GoldenDir -Filter "*.pdf" | Sort-Object Name
if ($goldenPdfs.Count -eq 0) { throw "No PDF files found in golden folder: $GoldenDir" }

Write-Host "Golden set: $($goldenPdfs.Count) document(s) in $GoldenDir" -ForegroundColor Cyan
Write-Host "Analyzers under test: $($AnalyzerIds -join ', ')" -ForegroundColor Cyan
Write-Host ""

# accuracy[analyzerId] = @{ matched = n; total = n; confSum = n; confCount = n }
$accuracy = @{}
foreach ($id in $AnalyzerIds) { $accuracy[$id] = @{ matched = 0; total = 0; confSum = 0.0; confCount = 0 } }

# Structured record of every document/field/analyzer comparison, for the saved JSON report.
$documentReports = [System.Collections.Generic.List[object]]::new()

foreach ($pdf in $goldenPdfs) {
  $baseName = [System.IO.Path]::GetFileNameWithoutExtension($pdf.Name)
  $expectedPath = Join-Path $GoldenDir "$baseName.expected.json"
  if (-not (Test-Path $expectedPath)) {
    Write-Host "Skipping $($pdf.Name) - no matching $baseName.expected.json" -ForegroundColor Yellow
    continue
  }
  $expected = Get-Content $expectedPath -Raw | ConvertFrom-Json

  Write-Host "=== $baseName ===" -ForegroundColor White

  $resultsByAnalyzer = @{}
  foreach ($analyzerId in $AnalyzerIds) {
    Write-Host "  Analyzing with '$analyzerId'..." -NoNewline
    $result = Invoke-AnalyzeBinary -AnalyzerId $analyzerId -FilePath $pdf.FullName
    $resultsByAnalyzer[$analyzerId] = $result
    Write-Host " done"
  }

  # Only compare fields present in the expected ground truth (schemas may only cover a subset).
  $fieldNames = $expected.PSObject.Properties.Name
  $fieldReports = [System.Collections.Generic.List[object]]::new()
  $rows = foreach ($fieldName in $fieldNames) {
    $row = [ordered]@{ Field = $fieldName; Expected = ($expected.$fieldName | ConvertTo-Json -Compress -Depth 5) }
    $analyzerResults = [ordered]@{}
    foreach ($analyzerId in $AnalyzerIds) {
      $actualValue = $resultsByAnalyzer[$analyzerId].values[$fieldName]
      $confidence = $resultsByAnalyzer[$analyzerId].confidences[$fieldName]
      $isMatch = Test-ValueMatch $expected.$fieldName $actualValue
      $accuracy[$analyzerId].total++
      if ($isMatch) { $accuracy[$analyzerId].matched++ }
      if ($null -ne $confidence) { $accuracy[$analyzerId].confSum += $confidence; $accuracy[$analyzerId].confCount++ }
      $confSuffix = if ($null -ne $confidence) { " [conf: $([Math]::Round($confidence, 2))]" } else { "" }
      $row["$analyzerId"] = if ($isMatch) { "OK$confSuffix" } else { "MISMATCH$confSuffix ($([string]($actualValue | ConvertTo-Json -Compress -Depth 5)))" }
      $analyzerResults[$analyzerId] = [ordered]@{
        actual     = $actualValue
        confidence = $confidence
        matched    = $isMatch
      }
    }
    $fieldReports.Add([ordered]@{
      field    = $fieldName
      expected = $expected.$fieldName
      results  = $analyzerResults
    })
    [pscustomobject]$row
  }
  $rows | Format-Table -AutoSize -Wrap | Out-String -Width 4096 | Write-Host

  $documentReports.Add([ordered]@{
    document = $baseName
    fields   = $fieldReports
  })
}

Write-Host ""
Write-Host "=== Accuracy summary ===" -ForegroundColor Cyan
$analyzerSummaries = [ordered]@{}
foreach ($analyzerId in $AnalyzerIds) {
  $a = $accuracy[$analyzerId]
  $pct = if ($a.total -gt 0) { [Math]::Round(100 * $a.matched / $a.total, 1) } else { 0 }
  $avgConf = if ($a.confCount -gt 0) { [Math]::Round($a.confSum / $a.confCount, 3) } else { $null }
  $confDisplay = if ($null -ne $avgConf) { "avg confidence: $avgConf" } else { "avg confidence: n/a (estimateFieldSourceAndConfidence not enabled/returned)" }
  Write-Host ("  {0,-25} {1}/{2} fields matched ({3}%), {4}" -f $analyzerId, $a.matched, $a.total, $pct, $confDisplay)
  $analyzerSummaries[$analyzerId] = [ordered]@{
    matched        = $a.matched
    total          = $a.total
    accuracyPct    = $pct
    avgConfidence  = $avgConf
  }
}

# ---------- Save structured results report ----------
if ($SaveResults) {
  if (-not $ResultsDir) {
    if ($Family) {
      $ResultsDir = Join-Path $PSScriptRoot "..\analyzers\$Family\results"
    } else {
      Write-Warning "SaveResults requested but no -Family or -ResultsDir supplied; skipping save."
    }
  }

  if ($ResultsDir) {
    New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
    $timestamp = Get-Date -AsUTC -Format "yyyyMMddTHHmmssZ"
    $safeIds = ($AnalyzerIds -join "_")
    $reportPath = Join-Path $ResultsDir "$timestamp`_$Environment`_$safeIds.json"

    $gitCommit = (git -C $PSScriptRoot rev-parse HEAD 2>$null)

    $report = [ordered]@{
      timestamp    = (Get-Date -AsUTC -Format "o")
      environment  = $Environment
      endpoint     = $Endpoint
      family       = $Family
      analyzerIds  = $AnalyzerIds
      apiVersion   = $ApiVersion
      goldenDir    = $GoldenDir
      gitCommit    = $gitCommit
      summary      = $analyzerSummaries
      documents    = $documentReports
    }

    $report | ConvertTo-Json -Depth 10 | Set-Content -Path $reportPath -Encoding utf8
    Write-Host ""
    Write-Host "Saved comparison report to $reportPath" -ForegroundColor Green
    Write-Host "  Commit it with: git add `"$reportPath`" && git commit -m `"${Family}: compare $($AnalyzerIds -join ' vs ')`"" -ForegroundColor Yellow
  }
}
