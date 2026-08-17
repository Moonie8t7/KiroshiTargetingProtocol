# ---------------------------------------------------------------------------
# HOW TO RUN THIS
#
#   powershell -ExecutionPolicy Bypass -File .\tools\deploy.ps1
#
# A bare `.\tools\deploy.ps1` fails on a default Windows 11 box: the client
# default ExecutionPolicy is Restricted, which blocks every .ps1. The form above
# works regardless of policy and changes no machine-wide setting. Arguments go
# after the script path:
#
#   powershell -ExecutionPolicy Bypass -File .\tools\deploy.ps1 -WhatIf
#   powershell -ExecutionPolicy Bypass -File .\tools\deploy.ps1 -Clean -WhatIf
#   powershell -ExecutionPolicy Bypass -File .\tools\deploy.ps1 -GamePath 'D:\Games\Cyberpunk 2077'
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Deploys Kiroshi Smart Targeting Protocol (KSTP) into a Cyberpunk 2077 install.

.DESCRIPTION
    Copies the deployable trees of this project into the game directory,
    preserving structure:

        src\r6                     ->  <game>\r6
        src\archive                ->  <game>\archive     (excluding src\archive\source)
        experiments\cet\kstp_lab   ->  <game>\bin\x64\plugins\cyber_engine_tweaks\mods\kstp_lab

    src\r6 carries the redscript, the TweakXL tweaks, the Input Loader XML and the
    redsUserHints config. KSTP ships no .archive and no .xl, since its display strings
    are registered from script (ADR 0008), so src\archive is absent as the project
    stands and its mapping deploys nothing; it is kept for a build that produces one.
    Where that tree does exist, src\archive\source is WolvenKit CR2W build input the
    game cannot read, so the mapping excludes it. The whole archive mapping is optional:
    if src\archive is missing or empty the deploy reports that and carries on.

    The target install is resolved from -GamePath, then $env:KSTP_GAME_PATH, then
    the $DefaultGamePath value near the top of this script. That default is a
    convenience for one machine, not an assumption about where the game lives; set
    KSTP_GAME_PATH once and every tool in tools\ picks it up.

    Every file written is recorded in a per-install manifest kept inside this
    project, never inside the game. -Clean replays that manifest and removes
    exactly those files.

.PARAMETER GamePath
    Cyberpunk 2077 install root, overriding $env:KSTP_GAME_PATH and $DefaultGamePath.
    The path must contain bin\x64\Cyberpunk2077.exe or the script refuses to write
    to it.

.PARAMETER Clean
    Remove every file recorded in this install's manifest, then prune the empty
    KSTP-owned directories left behind. Safety behavior:
      - only files listed in the manifest, plus the files the current source tree
        would deploy, are candidates for removal
      - a candidate path that resolves outside the game root aborts the run
      - a directory is pruned only when it is at least two segments deep, carries a
        KSTP or kstp_lab path segment or is one of the legacy archive\source
        directories, is not a vanilla or framework directory, is not a junction or
        symlink, and is empty
      - directory removal goes through [System.IO.Directory]::Delete(path, $false),
        which throws on a non-empty directory rather than recursing
    Combine with -WhatIf to list every removal without performing one.

.PARAMETER Force
    Copy every file even when the destination already matches by size and
    timestamp. Useful after a partial or interrupted deploy.

.PARAMETER Quiet
    Print only the summary line, not the per-file listing.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\deploy.ps1 -WhatIf
    Dry run against the resolved install. Shows exactly what would be written.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\deploy.ps1 -GamePath 'D:\Games\Cyberpunk 2077'
    Deploy to a specific install, ignoring KSTP_GAME_PATH and the script default.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\deploy.ps1 -Clean -WhatIf
    List every file that would be removed, without removing anything.

.NOTES
    KSTP tools version 1.0.0.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string] $GamePath,
    [switch] $Clean,
    [switch] $Force,
    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Version reported in the banner line below.
$KSTPVersion = '1.0.0'

# -WhatIf is honored by this script's own printing rather than by ShouldProcess, so a
# dry run reads the same as a real run instead of emitting stock "What if:" lines.
$DryRun = [bool]$WhatIfPreference

# Last-resort default, used only when neither -GamePath nor $env:KSTP_GAME_PATH is set.
# Edit it to match the install this working copy targets, or set KSTP_GAME_PATH and leave
# it alone. Deploying to the wrong copy of the game reports success and then changes
# nothing in the copy that actually launches, so the resolved path is printed on every
# run alongside where it came from.
$DefaultGamePath = 'C:\Program Files (x86)\Steam\steamapps\common\Cyberpunk 2077'
$ProjectRoot     = Split-Path -Parent $PSScriptRoot
$ManifestDir     = Join-Path $PSScriptRoot '.deploy-manifests'

# Editor droppings and VCS metadata never belong in a game install.
$IgnoreNamePatterns = @('*.bak', '*.tmp', '*.swp', '*~', 'Thumbs.db', 'desktop.ini', '.DS_Store', '*.orig', '*.rej')
$IgnoreDirNames     = @('.git', '.svn', '.vs', '.idea', 'node_modules', '__pycache__')

# Directories that exist in a vanilla or framework install. Never pruned, even when empty.
$ProtectedRelDirs = @(
    'r6', 'r6\scripts', 'r6\tweaks', 'r6\input', 'r6\cache', 'r6\cache\modded', 'r6\config',
    'r6\logs', 'r6\storages', 'archive', 'archive\pc', 'archive\pc\mod', 'archive\pc\content',
    'bin', 'bin\x64', 'bin\x64\plugins', 'bin\x64\plugins\cyber_engine_tweaks',
    'bin\x64\plugins\cyber_engine_tweaks\mods', 'red4ext', 'red4ext\plugins',
    'engine', 'engine\tools', 'mods'
)

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

function Write-Head([string] $Text) {
    Write-Host ''
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('-' * $Text.Length) -ForegroundColor DarkCyan
}

function Write-Item([string] $Status, [string] $Path, [ConsoleColor] $Color) {
    if ($Quiet) { return }
    Write-Host ('  {0,-8} ' -f $Status) -ForegroundColor $Color -NoNewline
    Write-Host $Path
}

function Write-Note([string] $Text) { Write-Host "  $Text" -ForegroundColor DarkGray }
function Write-Warn([string] $Text) { Write-Host "  WARN     $Text" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# ExecutionPolicy self-diagnosis
#
# A run launched with -ExecutionPolicy Bypass makes Get-ExecutionPolicy report Bypass,
# which says nothing about what the next bare invocation will do. The persisted policy
# is what matters: the first non-Undefined value across MachinePolicy, UserPolicy,
# CurrentUser and LocalMachine. When that is restrictive (or Undefined, which on Windows
# client means Restricted), a bare `.\tools\deploy.ps1` in a fresh shell is blocked, so
# print the invocation form that always works.
# ---------------------------------------------------------------------------

function Get-KSTPPersistedPolicy {
    try { $entries = @(Get-ExecutionPolicy -List -ErrorAction Stop) } catch { return $null }
    foreach ($scope in @('MachinePolicy', 'UserPolicy', 'CurrentUser', 'LocalMachine')) {
        $match = $entries | Where-Object { $_.Scope.ToString() -eq $scope } | Select-Object -First 1
        if ($null -ne $match -and $match.ExecutionPolicy.ToString() -ne 'Undefined') {
            return $match.ExecutionPolicy.ToString()
        }
    }
    return 'Undefined'
}

function Write-KSTPPolicyHint([string] $ScriptRelPath) {
    $persisted = Get-KSTPPersistedPolicy
    if ($null -eq $persisted) { return }
    if (@('Restricted', 'AllSigned', 'Undefined') -notcontains $persisted) { return }

    $shown = if ($persisted -eq 'Undefined') { 'Undefined (Restricted on Windows client)' } else { $persisted }
    Write-Host ''
    Write-Host "  ExecutionPolicy on this machine is $shown." -ForegroundColor Yellow
    Write-Host "  A bare .\$ScriptRelPath will be blocked in a fresh shell. Always invoke as:" -ForegroundColor Yellow
    Write-Host "    powershell -ExecutionPolicy Bypass -File .\$ScriptRelPath" -ForegroundColor White
    Write-Note 'That is per-process only; it changes no machine-wide setting.'
}

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

function Get-RelPath([string] $Root, [string] $Full) {
    $normRoot = $Root.TrimEnd('\', '/') + '\'
    if ($Full.StartsWith($normRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $Full.Substring($normRoot.Length)
    }
    return $Full
}

# Refuses any destination that escapes the game root. Guards against a malformed
# mapping or a symlink in the source tree turning into a write outside the install.
function Assert-InsideGame([string] $GameRoot, [string] $Candidate) {
    $normRoot = [System.IO.Path]::GetFullPath($GameRoot.TrimEnd('\', '/')) + '\'
    $normCand = [System.IO.Path]::GetFullPath($Candidate)
    if (-not $normCand.StartsWith($normRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to touch '$normCand' - it resolves outside the game directory '$GameRoot'."
    }
    return $normCand
}

function Test-Ignored([System.IO.FileInfo] $File, [string] $SourceRoot) {
    foreach ($pattern in $IgnoreNamePatterns) {
        if ($File.Name -like $pattern) { return $true }
    }
    $rel = Get-RelPath -Root $SourceRoot -Full $File.FullName
    foreach ($segment in ($rel -split '\\')) {
        if ($IgnoreDirNames -contains $segment) { return $true }
    }
    return $false
}

# Per-mapping exclusion. $ExcludePrefixes are source-relative path prefixes matched
# whole-segment and case-insensitively, so 'source' excludes 'source\raw\...' but not
# a file literally named 'source.reds' and not 'resources\...'.
#
# Per-mapping rather than a global ignore list: 'source' is far too common a directory
# name to exclude across the whole project.
function Test-ExcludedRel([string] $Rel, [string[]] $ExcludePrefixes) {
    if ($null -eq $ExcludePrefixes -or $ExcludePrefixes.Count -eq 0) { return $false }
    $segments = @($Rel -split '\\')
    foreach ($prefix in $ExcludePrefixes) {
        $prefixSegments = @($prefix.Trim('\', '/') -split '\\')
        if ($prefixSegments.Count -gt $segments.Count) { continue }
        $matched = $true
        for ($i = 0; $i -lt $prefixSegments.Count; $i++) {
            if ($segments[$i] -ine $prefixSegments[$i]) { $matched = $false; break }
        }
        if ($matched) { return $true }
    }
    return $false
}

function Get-ManifestPath([string] $GameRoot) {
    $key  = [System.IO.Path]::GetFullPath($GameRoot.TrimEnd('\', '/')).ToLowerInvariant()
    $md5  = [System.Security.Cryptography.MD5]::Create()
    $hash = ($md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($key)) | ForEach-Object { $_.ToString('x2') }) -join ''
    $md5.Dispose()
    return (Join-Path $ManifestDir "$hash.txt")
}

# ---------------------------------------------------------------------------
# Resolve and validate the target install
# ---------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($GamePath)) {
    if (-not [string]::IsNullOrWhiteSpace($env:KSTP_GAME_PATH)) {
        $GamePath = $env:KSTP_GAME_PATH
        $gameSource = 'KSTP_GAME_PATH'
    } else {
        $GamePath = $DefaultGamePath
        $gameSource = 'script default'
    }
} else {
    $gameSource = '-GamePath'
}

if (-not (Test-Path -LiteralPath $GamePath -PathType Container)) {
    throw "Game directory not found: '$GamePath' (from $gameSource). Pass -GamePath or set KSTP_GAME_PATH."
}
$GamePath = (Resolve-Path -LiteralPath $GamePath).ProviderPath.TrimEnd('\')

$gameExe = Join-Path $GamePath 'bin\x64\Cyberpunk2077.exe'
if (-not (Test-Path -LiteralPath $gameExe -PathType Leaf)) {
    throw "'$GamePath' does not look like a Cyberpunk 2077 install (bin\x64\Cyberpunk2077.exe is missing). Refusing to write there."
}

$manifestPath = Get-ManifestPath -GameRoot $GamePath

Write-Host ''
Write-Host "KSTP deploy $KSTPVersion" -ForegroundColor White
Write-Note "project  : $ProjectRoot"
Write-Note "game     : $GamePath  (from $gameSource)"
Write-Note "manifest : $manifestPath"
if ($DryRun) { Write-Host '  MODE     DRY RUN - nothing is written' -ForegroundColor Yellow }

Write-KSTPPolicyHint 'tools\deploy.ps1'

# ---------------------------------------------------------------------------
# Deployment map
# ---------------------------------------------------------------------------

$mappings = @(
    [pscustomobject]@{
        Name       = 'redscript + tweaks + input + config'
        Source     = Join-Path $ProjectRoot 'src\r6'
        Dest       = Join-Path $GamePath 'r6'
        Required   = $true
        ExcludeRel = @()
    }
    [pscustomobject]@{
        Name       = 'archive (.xl manifests)'
        Source     = Join-Path $ProjectRoot 'src\archive'
        Dest       = Join-Path $GamePath 'archive'
        Required   = $false
        # No src\archive tree is shipped: display strings are registered from script
        # rather than packed (ADR 0008), so this mapping currently deploys nothing.
        # Where one is built, src\archive\source is the WolvenKit project - raw CR2W and
        # .json.json build input that only WolvenKit reads - and only the packed side of
        # src\archive (pc\mod\*.xl, and a .archive if one is ever produced) is deployable.
        ExcludeRel = @('source')
    }
    [pscustomobject]@{
        Name       = 'CET experiment lab'
        Source     = Join-Path $ProjectRoot 'experiments\cet\kstp_lab'
        Dest       = Join-Path $GamePath 'bin\x64\plugins\cyber_engine_tweaks\mods\kstp_lab'
        Required   = $false
        ExcludeRel = @()
    }
)

# Enumerate every file the current source tree would deploy.
# Returns objects carrying both the absolute destination and the game-relative path.
function Get-PlannedFiles {
    $planned = New-Object System.Collections.Generic.List[object]
    foreach ($map in $mappings) {
        if (-not (Test-Path -LiteralPath $map.Source -PathType Container)) { continue }
        $sourceRoot = (Resolve-Path -LiteralPath $map.Source).ProviderPath.TrimEnd('\')
        $files = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force -ErrorAction SilentlyContinue)
        foreach ($file in $files) {
            if (Test-Ignored -File $file -SourceRoot $sourceRoot) { continue }
            $rel      = Get-RelPath -Root $sourceRoot -Full $file.FullName
            if (Test-ExcludedRel -Rel $rel -ExcludePrefixes $map.ExcludeRel) { continue }
            $destFull = Assert-InsideGame -GameRoot $GamePath -Candidate (Join-Path $map.Dest $rel)
            $planned.Add([pscustomobject]@{
                Mapping = $map
                Source  = $file
                Dest    = $destFull
                GameRel = (Get-RelPath -Root $GamePath -Full $destFull)
            })
        }
    }
    return $planned
}

# ---------------------------------------------------------------------------
# CLEAN
# ---------------------------------------------------------------------------

if ($Clean) {
    Write-Head 'Clean'

    # Union of the recorded manifest (catches files deleted from src since the last
    # deploy) and the current source tree (catches a fresh clone with no manifest).
    $targets = New-Object System.Collections.Generic.List[string]

    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        foreach ($line in (Get-Content -LiteralPath $manifestPath)) {
            $trimmed = $line.Trim()
            if ($trimmed -and -not $trimmed.StartsWith('#')) { $targets.Add($trimmed) }
        }
        Write-Note "manifest lists $($targets.Count) file(s)"
    } else {
        Write-Note 'no manifest for this install - falling back to the current source tree'
    }

    foreach ($item in (Get-PlannedFiles)) {
        if (-not $targets.Contains($item.GameRel)) { $targets.Add($item.GameRel) }
    }

    # Legacy cleanup. Older KSTP deploys mapped src\archive wholesale and so copied
    # src\archive\source\raw\... (WolvenKit build input) into <game>\archive\source. No
    # vanilla install and no framework uses that path, so anything found under it belongs
    # to KSTP. Those files are listed individually and go through the same guarded
    # per-file removal loop as everything else.
    $legacyArchiveSource = Join-Path $GamePath 'archive\source'
    if (Test-Path -LiteralPath $legacyArchiveSource -PathType Container) {
        $stale = @(Get-ChildItem -LiteralPath $legacyArchiveSource -Recurse -File -Force -ErrorAction SilentlyContinue)
        if ($stale.Count -gt 0) {
            Write-Note "found $($stale.Count) stale file(s) under archive\source from an older deploy"
            foreach ($file in $stale) {
                $staleRel = Get-RelPath -Root $GamePath -Full $file.FullName
                if (-not $targets.Contains($staleRel)) { $targets.Add($staleRel) }
            }
        }
    }

    $removed = 0
    $absent  = 0
    $touchedDirs = New-Object System.Collections.Generic.HashSet[string]
    # Under -WhatIf nothing is removed, so the prune pass would see every directory as
    # non-empty. Tracking what a real run would delete lets the prune pass discount those
    # entries, so the dry run reports the same directory count as a real run.
    $goneSet = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($rel in ($targets | Sort-Object)) {
        $full = Assert-InsideGame -GameRoot $GamePath -Candidate (Join-Path $GamePath $rel)
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            if (-not $DryRun) { Remove-Item -LiteralPath $full -Force }
            Write-Item 'REMOVE' $rel Red
            $removed++
            [void]$goneSet.Add($full)
            [void]$touchedDirs.Add((Split-Path -Parent $full))
        } else {
            Write-Item 'ABSENT' $rel DarkGray
            $absent++
        }
    }

    # Prune only KSTP-owned directories. Every one of these must hold before a directory
    # is touched:
    #   - it is strictly inside the game root (prefix test, not a length test)
    #   - it is at least two segments deep, so no top-level game directory qualifies
    #   - it is not in $ProtectedRelDirs
    #   - it carries a KSTP or kstp_lab segment, or is one of the legacy archive\source
    #     directories an older deploy created
    #   - it is a real directory, not a junction or symlink
    #   - it is empty once the files removed above are discounted
    # Deepest first, so a nested tree collapses in one pass.
    $gameRootNorm = [System.IO.Path]::GetFullPath($GamePath.TrimEnd('\', '/'))
    $gameRootPrefix = $gameRootNorm + '\'

    # Directories that only exist because an older deploy copied the WolvenKit source
    # tree in. They hold no KSTP segment of their own, so name them explicitly.
    $LegacyOwnedRelDirs = @('archive\source', 'archive\source\raw')

    $prunable = @($touchedDirs) | ForEach-Object {
        $dir = $_
        while ($dir -and $dir.StartsWith($gameRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $dir
            $dir = Split-Path -Parent $dir
        }
    } | Sort-Object -Unique | Sort-Object -Property Length -Descending

    $prunedCount = 0
    foreach ($dir in $prunable) {
        $rel = Get-RelPath -Root $GamePath -Full $dir
        if ($ProtectedRelDirs -contains $rel) { continue }

        $segments = @($rel -split '\\')
        # A one-segment rel path is a top-level directory of the install. Never ours.
        if ($segments.Count -lt 2) { continue }

        $owned = $LegacyOwnedRelDirs -contains $rel
        if (-not $owned) {
            foreach ($seg in $segments) {
                if ($seg -ieq 'KSTP' -or $seg -ieq 'kstp_lab') { $owned = $true; break }
            }
        }
        if (-not $owned) { continue }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }

        # This path was derived by walking parents, so re-assert that it still resolves
        # inside the install before anything is deleted.
        [void](Assert-InsideGame -GameRoot $GamePath -Candidate $dir)

        $dirItem = Get-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
        if ($null -ne $dirItem -and (($dirItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
            Write-Warn "kept '$rel' - it is a junction or symlink, not a directory this script created"
            continue
        }

        $leftovers = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue |
                       Where-Object { -not $goneSet.Contains($_.FullName) })
        if ($leftovers.Count -gt 0) {
            Write-Warn "kept '$rel' - $($leftovers.Count) item(s) not deployed by KSTP are still in it"
            continue
        }

        # Non-recursive by construction. Remove-Item without -Recurse can still perform
        # a recursive delete on Windows PowerShell 5.1 when the "has children" prompt is
        # auto-answered. The .NET call has no such prompt: it throws IOException on a
        # non-empty directory, on every PowerShell version.
        if (-not $DryRun) {
            try {
                [System.IO.Directory]::Delete($dir, $false)
            } catch {
                Write-Warn "kept '$rel' - $($_.Exception.Message)"
                continue
            }
        }
        [void]$goneSet.Add($dir)
        Write-Item 'RMDIR' $rel DarkRed
        $prunedCount++
    }

    if (-not $DryRun -and (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        Remove-Item -LiteralPath $manifestPath -Force
        Write-Item 'FORGET' (Get-RelPath -Root $ProjectRoot -Full $manifestPath) DarkGray
    }

    Write-Host ''
    $verb = if ($DryRun) { 'would remove' } else { 'removed' }
    Write-Host ("KSTP clean: {0} {1} file(s), {2} already absent, {3} empty dir(s) pruned." -f $verb, $removed, $absent, $prunedCount) -ForegroundColor Green
    Write-Host ''
    return
}

# ---------------------------------------------------------------------------
# DEPLOY
# ---------------------------------------------------------------------------

$stats = [ordered]@{ New = 0; Update = 0; Same = 0; Skipped = 0 }
$writtenRel = New-Object System.Collections.Generic.List[string]

foreach ($map in $mappings) {
    Write-Head ("{0}  ({1})" -f $map.Name, (Get-RelPath -Root $ProjectRoot -Full $map.Source))

    # An absent or empty optional tree is a normal state. src\archive in particular may
    # not exist at all, since KSTP ships no .archive.
    if (-not (Test-Path -LiteralPath $map.Source -PathType Container)) {
        if ($map.Required) {
            throw "Required source tree missing: '$($map.Source)'. Nothing was deployed for this mapping."
        }
        Write-Note 'not present - nothing to deploy for this mapping'
        continue
    }

    $sourceRoot = (Resolve-Path -LiteralPath $map.Source).ProviderPath.TrimEnd('\')
    $files = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force -ErrorAction SilentlyContinue)

    if ($files.Count -eq 0) {
        if ($map.Required) {
            throw "Required source tree is empty: '$($map.Source)'. Nothing was deployed for this mapping."
        }
        Write-Note 'empty - nothing to deploy for this mapping'
        continue
    }

    $deployedFromMap = 0

    foreach ($file in ($files | Sort-Object FullName)) {
        if (Test-Ignored -File $file -SourceRoot $sourceRoot) {
            Write-Item 'SKIP' (Get-RelPath -Root $sourceRoot -Full $file.FullName) DarkGray
            $stats.Skipped++
            continue
        }

        $rel      = Get-RelPath -Root $sourceRoot -Full $file.FullName

        # Build input, not deployable content. Never goes near the game install.
        if (Test-ExcludedRel -Rel $rel -ExcludePrefixes $map.ExcludeRel) {
            Write-Item 'EXCLUDE' $rel DarkGray
            $stats.Skipped++
            continue
        }

        $destFull = Assert-InsideGame -GameRoot $GamePath -Candidate (Join-Path $map.Dest $rel)
        $gameRel  = Get-RelPath -Root $GamePath -Full $destFull

        $existing = Get-Item -LiteralPath $destFull -ErrorAction SilentlyContinue
        $status   = 'NEW'
        $colour   = [ConsoleColor]::Green

        if ($null -ne $existing) {
            $unchanged = ($existing.Length -eq $file.Length) -and
                         ($existing.LastWriteTimeUtc -eq $file.LastWriteTimeUtc)
            if ($unchanged -and -not $Force) {
                Write-Item 'SAME' $gameRel DarkGray
                $stats.Same++
                $writtenRel.Add($gameRel)
                $deployedFromMap++
                continue
            }
            $status = 'UPDATE'
            $colour = [ConsoleColor]::Yellow
        }

        if (-not $DryRun) {
            $destDir = Split-Path -Parent $destFull
            if (-not (Test-Path -LiteralPath $destDir -PathType Container)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }
            # Copy then stamp, so the size+timestamp comparison above stays meaningful.
            Copy-Item -LiteralPath $file.FullName -Destination $destFull -Force
            (Get-Item -LiteralPath $destFull).LastWriteTimeUtc = $file.LastWriteTimeUtc
        }

        Write-Item $status $gameRel $colour
        if ($status -eq 'NEW') { $stats.New++ } else { $stats.Update++ }
        $writtenRel.Add($gameRel)
        $deployedFromMap++
    }

    if ($deployedFromMap -eq 0) {
        Write-Note 'nothing deployable in this tree - every file was ignored or excluded'
    }
}

if (-not $DryRun) {
    if (-not (Test-Path -LiteralPath $ManifestDir -PathType Container)) {
        New-Item -ItemType Directory -Path $ManifestDir -Force | Out-Null
    }
    $header = @(
        "# KSTP deploy manifest $KSTPVersion - generated file, do not edit by hand.",
        "# game    : $GamePath",
        "# written : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "# Paths are relative to the game root. deploy.ps1 -Clean removes exactly these."
    )
    Set-Content -LiteralPath $manifestPath -Value ($header + ($writtenRel | Sort-Object -Unique)) -Encoding UTF8
}

Write-Host ''
$verb = if ($DryRun) { 'would deploy' } else { 'deployed' }
Write-Host ("KSTP {0}: {1} new, {2} updated, {3} unchanged, {4} ignored -> {5}" -f `
    $verb, $stats.New, $stats.Update, $stats.Same, $stats.Skipped, $GamePath) -ForegroundColor Green

if (-not $DryRun -and ($stats.New + $stats.Update) -gt 0) {
    Write-Note 'Redscript recompiles at game launch. Read r6\logs\redscript_rCURRENT.log after starting the game.'
    Write-Note 'Run tools\verify-env.ps1 if the mod does not appear in game.'
}
Write-Host ''
