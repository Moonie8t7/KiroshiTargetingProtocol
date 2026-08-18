# ---------------------------------------------------------------------------
# HOW TO RUN THIS
#
#   powershell -ExecutionPolicy Bypass -File .\tools\package.ps1
#
# A bare `.\tools\package.ps1` fails on a default Windows 11 box: the client
# default ExecutionPolicy is Restricted, which blocks every .ps1. The form above
# works regardless of policy and changes no machine-wide setting. Arguments go
# after the script path:
#
#   powershell -ExecutionPolicy Bypass -File .\tools\package.ps1 -WhatIf
#   powershell -ExecutionPolicy Bypass -File .\tools\package.ps1 -Version 0.2.0
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Builds the redistributable archive for Kiroshi Smart Targeting Protocol (KSTP).

.DESCRIPTION
    Produces dist\KSTP-<version>.zip, laid out so a player extracts it straight
    into the Cyberpunk 2077 install folder:

        src\r6              ->  r6
        src\archive\pc      ->  archive\pc

    Only those two trees ship. The WolvenKit project under src\archive\source is
    build input the game cannot read, the CET lab under experiments is a
    development tool, and tools and docs belong in the repository rather than in
    a player's game directory.

    The version comes from the VERSION file unless -Version overrides it.

    Every file that ships is listed before the archive is written, and the
    contents are checked afterwards against the same list, so a mismatch is an
    error rather than something a player discovers.

.PARAMETER Version
    Overrides the version read from VERSION. Affects the archive name only.

.PARAMETER OutDir
    Where to write the archive. Defaults to dist under the project root.

.PARAMETER Force
    Overwrite an existing archive of the same name.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $Version,
    [string] $OutDir,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DryRun = [bool]$WhatIfPreference

$ProjectRoot = Split-Path -Parent $PSScriptRoot

function Write-Head([string] $Text) { Write-Host ''; Write-Host $Text -ForegroundColor Cyan }
function Write-Note([string] $Text) { Write-Host "  $Text" -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------

if (-not $Version) {
    $versionFile = Join-Path $ProjectRoot 'VERSION'
    if (-not (Test-Path -LiteralPath $versionFile)) {
        throw "No VERSION file at '$versionFile', and no -Version given."
    }
    $Version = (Get-Content -LiteralPath $versionFile -Raw).Trim()
}

if ($Version -notmatch '^\d+\.\d+\.\d+') {
    throw "Version '$Version' is not a semantic version. Fix VERSION or pass -Version."
}

if (-not $OutDir) { $OutDir = Join-Path $ProjectRoot 'dist' }
$zipName = "KSTP-$Version.zip"
$zipPath = Join-Path $OutDir $zipName

Write-Host "KSTP package $Version" -ForegroundColor White

# ---------------------------------------------------------------------------
# What ships
#
# Source tree on the left, path inside the archive on the right. The right-hand
# side is relative to the game root, because that is where a player extracts.
# ---------------------------------------------------------------------------

$mappings = @(
    [pscustomobject]@{ Source = Join-Path $ProjectRoot 'src\r6';         Target = 'r6' }
    [pscustomobject]@{ Source = Join-Path $ProjectRoot 'src\archive\pc'; Target = 'archive\pc' }
)

# Carried alongside the scripts rather than at the archive root, so extracting
# leaves nothing loose in the player's game directory.
$extras = @(
    [pscustomobject]@{ Source = Join-Path $ProjectRoot 'LICENSE'; Target = 'r6\scripts\KSTP\LICENSE' }
)

foreach ($m in $mappings) {
    if (-not (Test-Path -LiteralPath $m.Source -PathType Container)) {
        throw "Required tree missing: '$($m.Source)'. Nothing was packaged."
    }
}

# Checked before staging rather than after. Discovering the collision at the end means
# printing a full contents listing that reads like success and then failing under it.
if ((Test-Path -LiteralPath $zipPath) -and -not $Force -and -not $DryRun) {
    throw "'$zipPath' already exists. Pass -Force to overwrite, or delete it."
}

# ---------------------------------------------------------------------------
# Stage
# ---------------------------------------------------------------------------

$staging = Join-Path ([System.IO.Path]::GetTempPath()) ("kstp-pkg-" + [System.Guid]::NewGuid().ToString('N'))

$planned = New-Object System.Collections.Generic.List[string]

Write-Head 'Contents'

foreach ($m in $mappings) {
    $root = (Resolve-Path -LiteralPath $m.Source).ProviderPath.TrimEnd('\')
    foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -File) {
        $rel = $f.FullName.Substring($root.Length).TrimStart('\')
        $inZip = Join-Path $m.Target $rel
        $planned.Add($inZip)
        Write-Host ("  {0,10:N0}  {1}" -f $f.Length, $inZip)
        if (-not $DryRun) {
            $dest = Join-Path $staging $inZip
            $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest)
            Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
        }
    }
}

foreach ($e in $extras) {
    if (-not (Test-Path -LiteralPath $e.Source)) { continue }
    $planned.Add($e.Target)
    Write-Host ("  {0,10:N0}  {1}" -f (Get-Item -LiteralPath $e.Source).Length, $e.Target)
    if (-not $DryRun) {
        $dest = Join-Path $staging $e.Target
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest)
        Copy-Item -LiteralPath $e.Source -Destination $dest -Force
    }
}

# ---------------------------------------------------------------------------
# Refuse to ship development files
#
# A cheap guard against a future mapping change quietly widening the archive.
# ---------------------------------------------------------------------------

$forbidden = @('source\', 'experiments\', 'tools\', 'docs\', '.git', '.projectFiles', '.cpmodproj', '.zip')
foreach ($p in $planned) {
    foreach ($bad in $forbidden) {
        if ($p -like "*$bad*") {
            if (-not $DryRun) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
            throw "Refusing to package development file '$p' (matched '$bad')."
        }
    }
}

Write-Note "$($planned.Count) file(s)"

if ($DryRun) {
    Write-Head 'Dry run'
    Write-Note "would write $zipPath"
    return
}

# ---------------------------------------------------------------------------
# Write and verify
# ---------------------------------------------------------------------------

if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

$null = New-Item -ItemType Directory -Force -Path $OutDir
# Both are needed under Windows PowerShell: FileSystem supplies ZipFile, and the base
# assembly supplies ZipArchive and ZipArchiveMode.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Written entry by entry rather than with Compress-Archive, which records Windows
# backslashes as the path separator. The ZIP appnote requires forward slashes, and an
# extractor that takes it literally produces one flat file per entry, named
# "r6\scripts\KSTP\Core\Gate.reds", instead of the directory tree the game needs.
$fs = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::Create)
try {
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($rel in $planned) {
            $entry = $zip.CreateEntry(($rel -replace '\\', '/'), [System.IO.Compression.CompressionLevel]::Optimal)
            $out = $entry.Open()
            try {
                $in = [System.IO.File]::OpenRead((Join-Path $staging $rel))
                try { $in.CopyTo($out) } finally { $in.Dispose() }
            } finally { $out.Dispose() }
        }
    } finally { $zip.Dispose() }
} finally { $fs.Dispose() }

$zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $badSep = @($zip.Entries | Where-Object { $_.FullName -like '*\*' }).Count
    $inZip = @($zip.Entries | Where-Object { $_.Name -ne '' } | ForEach-Object { $_.FullName -replace '/', '\' })
} finally {
    $zip.Dispose()
}

if ($badSep -gt 0) {
    throw "$badSep entry name(s) use a backslash separator. '$zipPath' is not fit to publish."
}

$missing = @($planned | Where-Object { $inZip -notcontains $_ })
$extra   = @($inZip   | Where-Object { $planned -notcontains $_ })

Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue

if ($missing.Count -or $extra.Count) {
    foreach ($m in $missing) { Write-Host "  MISSING FROM ARCHIVE  $m" -ForegroundColor Red }
    foreach ($x in $extra)   { Write-Host "  UNEXPECTED IN ARCHIVE $x" -ForegroundColor Red }
    throw "Archive contents do not match the plan. '$zipPath' is not fit to publish."
}

Write-Head 'Written'
Write-Note ("{0}  ({1:N0} bytes, {2} file(s))" -f $zipPath, (Get-Item -LiteralPath $zipPath).Length, $inZip.Count)
Write-Note 'Extracts into the Cyberpunk 2077 install folder. Verified against the plan above.'
