<#
.SYNOPSIS
  Promotes the current analyzers/<family>/analyzer.json to a new versioned Azure deployment,
  tags the git commit, and records the promotion in manifest.json.

.DESCRIPTION
  Local analyzer definitions are version-controlled as a single mutable file per family
  (analyzers/<family>/analyzer.json) - history lives in git, not in duplicate vN.json files.
  "Versions" only need to materialize as distinct objects when you deploy to Azure, because
  compare-analyzers.ps1 needs multiple live analyzerIds to diff against each other and against
  the golden set.

  This script:
    1. Reads analyzers/<family>/analyzer.json and analyzers/<family>/manifest.json.
    2. Determines the next version number (max existing promotion version + 1).
    3. Requires a clean git working tree for this file (so the tag points at an exact,
       reviewable commit) unless -AllowDirty is passed.
    4. Uploads analyzer.json to Azure as "<family>V<N>" via upload-analyzers.ps1.
    5. Creates an annotated git tag "<family>-v<N>" at the current commit.
    6. Appends a new entry to manifest.json's "promotions" array and updates "current".

.PARAMETER Endpoint
  The Content Understanding resource endpoint, e.g. https://myresource.cognitiveservices.azure.com

.PARAMETER Family
  The analyzer family folder name under analyzers/, e.g. "invoice".

.PARAMETER Notes
  Free-text note describing what changed in this promotion (stored in manifest.json).

.PARAMETER AllowDirty
  Skip the clean-working-tree check (not recommended - the whole point of tagging is that the
  deployed analyzerId maps to an exact, reviewable git commit).

.PARAMETER ApiVersion
  Content Understanding API version. Defaults to the current GA version.

.EXAMPLE
  # After editing analyzers/invoice/analyzer.json and committing the change:
  .\promote-analyzer.ps1 -Endpoint "https://byofoundrylfgymnr5a.cognitiveservices.azure.com" `
    -Family invoice -Notes "Adds BusinessPhone and ClientPhone fields."

.NOTES
  Compare the new version against a previous one before (or after) promoting with:
    .\compare-analyzers.ps1 -Endpoint <endpoint> -AnalyzerIds invoicev1, invoicev2
#>
param(
  [Parameter(Mandatory = $true)]
  [string]$Endpoint,

  [Parameter(Mandatory = $true)]
  [string]$Family,

  [Parameter(Mandatory = $true)]
  [string]$Notes,

  [switch]$AllowDirty,

  [string]$ApiVersion = "2025-11-01"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$familyDir = Join-Path $repoRoot "analyzers\$Family"
$analyzerFile = Join-Path $familyDir "analyzer.json"
$manifestFile = Join-Path $familyDir "manifest.json"

if (-not (Test-Path $analyzerFile)) { throw "Not found: $analyzerFile" }
if (-not (Test-Path $manifestFile)) { throw "Not found: $manifestFile" }

# ---------- Git safety check ----------
Push-Location $repoRoot
try {
  $relPath = "analyzers/$Family/analyzer.json"
  $dirty = git status --porcelain -- $relPath
  if ($dirty -and -not $AllowDirty) {
    throw "Uncommitted changes in $relPath. Commit them first (so the git tag points at an exact, reviewable version), or pass -AllowDirty to override."
  }

  $commitSha = (git rev-parse --short HEAD).Trim()
}
finally {
  Pop-Location
}

# ---------- Determine next version ----------
$manifest = Get-Content $manifestFile -Raw | ConvertFrom-Json
$existingVersions = @($manifest.promotions | ForEach-Object { $_.version })
$nextVersion = if ($existingVersions.Count -gt 0) { ($existingVersions | Measure-Object -Maximum).Maximum + 1 } else { 1 }
$analyzerId = ("$Family" + "v$nextVersion").ToLowerInvariant()
$gitTag = "$Family-v$nextVersion".ToLowerInvariant()

Write-Host "Promoting $Family analyzer.json (commit $commitSha) as '$analyzerId' (tag '$gitTag')..." -ForegroundColor Cyan

# ---------- Deploy to Azure ----------
& (Join-Path $PSScriptRoot "upload-analyzers.ps1") `
  -Endpoint $Endpoint `
  -AnalyzerFiles $analyzerFile `
  -AnalyzerIds $analyzerId `
  -ApiVersion $ApiVersion

# ---------- Tag the commit ----------
Push-Location $repoRoot
try {
  git tag -a $gitTag -m "$Family v${nextVersion}: $Notes"
  Write-Host "Created git tag '$gitTag'. Push it with: git push origin $gitTag" -ForegroundColor Yellow
}
finally {
  Pop-Location
}

# ---------- Update manifest.json ----------
foreach ($p in $manifest.promotions) {
  if ($p.status -eq "active") { $p.status = "superseded" }
}

$newPromotion = [ordered]@{
  version    = $nextVersion
  analyzerId = $analyzerId
  gitTag     = $gitTag
  commit     = $commitSha
  createdAt  = (Get-Date -Format "yyyy-MM-dd")
  status     = "active"
  notes      = $Notes
}

$promotions = @($manifest.promotions) + [pscustomobject]$newPromotion
$manifest.promotions = $promotions
$manifest.current = $analyzerId

$manifest | ConvertTo-Json -Depth 10 | Set-Content $manifestFile -Encoding utf8

Write-Host "Updated $manifestFile - current = $analyzerId" -ForegroundColor Green
Write-Host ""
Write-Host "Next: compare against the previous version with:" -ForegroundColor Cyan
Write-Host "  .\compare-analyzers.ps1 -Endpoint $Endpoint -AnalyzerIds <previousId>, $analyzerId"
