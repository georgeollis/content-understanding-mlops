<#
.SYNOPSIS
  Scaffolds a new analyzer family from analyzers/_template, with placeholders pre-filled.

.DESCRIPTION
  Copies analyzers/_template to analyzers/<Family>, then replaces the "<family>" placeholder
  in analyzer.json (tags.family) and manifest.dev.json (family/note) and, if -Description is
  supplied, the "<one-line description...>" placeholders in both files too. This is the
  fastest correct path to a new family - equivalent to manually copying _template and editing
  every placeholder by hand, minus the risk of missing one.

  This does not deploy anything or call Azure. See the printed "Next steps" for what to do
  after scaffolding, or docs/getting-started.md for the full walkthrough.

.PARAMETER Family
  New family name (folder under analyzers/, e.g. "invoice"). Must not already exist. Use
  lowercase, no spaces - it becomes part of every deployed analyzerId (e.g. "<family>v1").

.PARAMETER Description
  One-line description of what this analyzer extracts (shown in analyzers/README.md's family
  index). Optional - if omitted, the placeholder is left in place for you to fill in by hand.

.EXAMPLE
  .\new-analyzer.ps1 -Family receipt -Description "Extracts merchant, line items, and totals from retail receipts"
#>
param(
  [Parameter(Mandatory = $true)]
  [string]$Family,

  [string]$Description
)

$ErrorActionPreference = "Stop"

if ($Family -notmatch "^[a-z0-9-]+$") {
  throw "Family '$Family' should be lowercase letters/digits/hyphens only (it becomes part of every deployed analyzerId)."
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$templateDir = Join-Path $repoRoot "analyzers\_template"
$targetDir = Join-Path $repoRoot "analyzers\$Family"

if (Test-Path $targetDir) { throw "analyzers/$Family already exists." }

Copy-Item -Recurse $templateDir $targetDir
Write-Host "Copied analyzers/_template -> analyzers/$Family" -ForegroundColor Green

# Remove the template's own README (guidance for filling in _template itself, not relevant to a real family)
Remove-Item (Join-Path $targetDir "README.md") -ErrorAction SilentlyContinue

function Update-PlaceholderFile {
  param([string]$Path)
  $content = Get-Content $Path -Raw
  $content = $content.Replace("<family>", $Family)
  if ($Description) {
    $content = $content.Replace("<one-line description of what this analyzer extracts - shown in analyzers/README.md's family index>", $Description)
    $content = $content.Replace("<one-line description of what this analyzer extracts>", $Description)
  }
  Set-Content -Path $Path -Value $content -NoNewline
}

Update-PlaceholderFile (Join-Path $targetDir "analyzer.json")
Update-PlaceholderFile (Join-Path $targetDir "manifest.dev.json")

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Edit analyzers/$Family/analyzer.json - replace 'fieldSchema' with your real fields"
Write-Host "     (design it in Foundry Studio and export, or hand-write against schemas/analyzer.schema.json)."
if (-not $Description) {
  Write-Host "  2. Fill in the remaining '<one-line description...>' placeholders in analyzer.json and manifest.dev.json."
}
Write-Host "  3. Add golden/<name>.pdf + golden/<name>.expected.json (at least one pair)."
Write-Host "  4. pwsh -File .\schemas\build-ground-truth-schema.ps1 -Family $Family"
Write-Host "  5. pwsh -File .\schemas\build-golden-manifest.ps1 -Family $Family"
Write-Host "  6. pwsh -File .\scripts\ci-check.ps1"
Write-Host "  7. git add analyzers/$Family && git commit -m `"Add $Family analyzer`""
Write-Host "  8. pwsh -File .\scripts\promote-analyzer.ps1 -Environment dev -Family $Family -Notes `"Initial deployment`""
Write-Host ""
Write-Host "Full walkthrough: docs/getting-started.md" -ForegroundColor DarkGray
