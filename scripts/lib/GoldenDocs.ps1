# Shared helpers for locating golden-set source documents and mapping their file extension to
# the Content-Type Content Understanding's analyzeBinary API expects.
#
# Golden documents are NOT limited to PDF. Content Understanding's document analyzer accepts a
# broad range of document/image formats (see docs/mlops-pipeline.md's "Supported golden document
# formats" table, sourced from
# https://learn.microsoft.com/en-us/azure/ai-services/content-understanding/service-limits).
# Every script that discovers golden documents or uploads them via analyzeBinary should dot-source
# this file and use Get-GoldenDocFiles / Get-ContentTypeForExtension rather than hardcoding "*.pdf"
# or "application/pdf", so adding e.g. a .docx or .png golden document just works.

# Maps a lowercase file extension (with leading dot) to the Content-Type analyzeBinary expects.
# Covers the "Document and text" and "Image" input types from the service limits page above
# (audio/video analyzers are out of scope for this repo's golden-set tooling).
$script:GoldenDocContentTypeMap = @{
  ".pdf"  = "application/pdf"
  ".tiff" = "image/tiff"
  ".tif"  = "image/tiff"
  ".jpg"  = "image/jpeg"
  ".jpeg" = "image/jpeg"
  ".jpe"  = "image/jpeg"
  ".png"  = "image/png"
  ".bmp"  = "image/bmp"
  ".heif" = "image/heif"
  ".heic" = "image/heic"
  ".docx" = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
  ".docm" = "application/vnd.ms-word.document.macroEnabled.12"
  ".doc"  = "application/msword"
  ".xlsx" = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  ".xlsm" = "application/vnd.ms-excel.sheet.macroEnabled.12"
  ".xls"  = "application/vnd.ms-excel"
  ".pptx" = "application/vnd.openxmlformats-officedocument.presentationml.presentation"
  ".pptm" = "application/vnd.ms-powerpoint.presentation.macroEnabled.12"
  ".ppt"  = "application/vnd.ms-powerpoint"
  ".odt"  = "application/vnd.oasis.opendocument.text"
  ".ods"  = "application/vnd.oasis.opendocument.spreadsheet"
  ".odp"  = "application/vnd.oasis.opendocument.presentation"
  ".epub" = "application/epub+zip"
  ".txt"  = "text/plain"
  ".html" = "text/html"
  ".md"   = "text/markdown"
  ".rtf"  = "application/rtf"
  ".xml"  = "application/xml"
  ".json" = "application/json"
  ".csv"  = "text/csv"
  ".tsv"  = "text/tab-separated-values"
  ".kml"  = "application/vnd.google-earth.kml+xml"
  ".eml"  = "message/rfc822"
  ".msg"  = "application/vnd.ms-outlook"
}

# All extensions golden-set discovery will look for (keys of the map above), as a glob-friendly
# array for Get-ChildItem -Include.
$script:GoldenDocExtensions = @($script:GoldenDocContentTypeMap.Keys)

function Get-ContentTypeForExtension {
  <#
  .SYNOPSIS
    Returns the Content-Type header value analyzeBinary expects for a given file extension.
  #>
  param([Parameter(Mandatory = $true)][string]$Extension)

  $ext = $Extension.ToLowerInvariant()
  if (-not $ext.StartsWith(".")) { $ext = ".$ext" }

  $contentType = $script:GoldenDocContentTypeMap[$ext]
  if (-not $contentType) {
    throw "Unsupported golden document extension '$Extension'. Supported: $($script:GoldenDocExtensions -join ', ')"
  }
  return $contentType
}

function Get-GoldenDocFiles {
  <#
  .SYNOPSIS
    Lists golden-set source documents (any supported format, not just *.pdf) in a golden folder,
    sorted by name. Ignores *.expected.json, *.schema.json, manifest.json, and any other
    non-source-document file.
  #>
  param([Parameter(Mandatory = $true)][string]$GoldenDir)

  Get-ChildItem -Path $GoldenDir -File |
    Where-Object { $script:GoldenDocExtensions -contains $_.Extension.ToLowerInvariant() } |
    # .json is a valid golden document extension (Content Understanding accepts plain JSON
    # input), but golden/ folders also contain sidecar *.expected.json, *.schema.json, and
    # manifest.json files that must never be treated as source documents themselves.
    Where-Object {
      $_.Name -notlike "*.expected.json" -and
      $_.Name -notlike "*.schema.json" -and
      $_.Name -ne "manifest.json"
    } |
    Sort-Object Name
}
