function Resolve-EnvironmentConfigEntry {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,

    [Parameter(Mandatory = $true)]
    [string]$Environment,

    [string]$Family
  )

  $rootPath = Join-Path $RepoRoot "environments.json"
  $familyPath = $null
  if ($Family) {
    $familyPath = Join-Path $RepoRoot "analyzers" $Family "environments.json"
  }

  $familyEntry = $null
  if ($familyPath -and (Test-Path $familyPath)) {
    $familyConfig = Get-Content $familyPath -Raw | ConvertFrom-Json
    $familyEntry = $familyConfig.environments.$Environment
  }

  $rootEntry = $null
  if (Test-Path $rootPath) {
    $rootConfig = Get-Content $rootPath -Raw | ConvertFrom-Json
    $rootEntry = $rootConfig.environments.$Environment
  }

  if ($familyEntry -and $rootEntry) {
    $merged = [ordered]@{}
    foreach ($prop in $rootEntry.PSObject.Properties) {
      $merged[$prop.Name] = $prop.Value
    }
    foreach ($prop in $familyEntry.PSObject.Properties) {
      $merged[$prop.Name] = $prop.Value
    }
    return [pscustomobject]@{
      Path  = "$familyPath (overrides) + $rootPath"
      Entry = [pscustomobject]$merged
    }
  }

  if ($familyEntry) {
    return [pscustomobject]@{
      Path  = $familyPath
      Entry = $familyEntry
    }
  }

  if ($rootEntry) {
    return [pscustomobject]@{
      Path  = $rootPath
      Entry = $rootEntry
    }
  }

  if ($familyPath -and (Test-Path $familyPath)) {
    throw "Environment '$Environment' not found in $familyPath or $rootPath."
  }

  if ($familyPath) {
    throw "Environment '$Environment' not found in $rootPath. Add it there, or create $familyPath with an 'environments.$Environment' entry."
  }

  throw "Environment '$Environment' not found in $rootPath."
}
