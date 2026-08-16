# ---------------------------------------------------------------------------
# HOW TO RUN THIS
#
#   powershell -ExecutionPolicy Bypass -File .\tools\verify-env.ps1
#
# A bare `.\tools\verify-env.ps1` fails on a default Windows 11 box: the client
# default ExecutionPolicy is Restricted, which blocks every .ps1. The form above
# works regardless of policy and changes no machine-wide setting. Arguments go
# after the script path:
#
#   powershell -ExecutionPolicy Bypass -File .\tools\verify-env.ps1 -Strict
#   powershell -ExecutionPolicy Bypass -File .\tools\verify-env.ps1 -GamePath 'D:\Games\Cyberpunk 2077'
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Checks that a Cyberpunk 2077 install can run KSTP, and prints where the logs
    live when it cannot.

.DESCRIPTION
    Read-only. Writes nothing and changes nothing.

    Reports four things:
      1. Whether the game directory is a Cyberpunk 2077 install.
      2. Which mod frameworks are INSTALLED and which are MISSING, split into the
         ones KSTP requires and the ones that unlock optional features.
      3. Whether KSTP is currently deployed there.
      4. Every log path worth opening when something goes wrong, starting with the
         redscript compile log, where a broken .reds file shows up.

.PARAMETER GamePath
    Cyberpunk 2077 install root, overriding $env:KSTP_GAME_PATH and $DefaultGamePath.

.PARAMETER Strict
    Exit with code 1 when any required framework is missing. Suited to CI or a
    pre-launch check. Without it the script is informational and always exits 0.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\verify-env.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\verify-env.ps1 -GamePath 'D:\Games\Cyberpunk 2077' -Strict

.NOTES
    KSTP tools version 1.0.0.
#>
[CmdletBinding()]
param(
    [string] $GamePath,
    [switch] $Strict
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Version reported in the banner line below.
$KSTPVersion = '1.0.0'

# Last-resort default, used only when neither -GamePath nor $env:KSTP_GAME_PATH is set.
# Keep it aligned with the same value in deploy.ps1, or set KSTP_GAME_PATH and let both
# tools read it. A machine with more than one copy of the game installed needs the
# override; checking the wrong copy reports a clean environment for an install that is
# never launched.
$DefaultGamePath = 'C:\Program Files (x86)\Steam\steamapps\common\Cyberpunk 2077'
$ProjectRoot     = Split-Path -Parent $PSScriptRoot

function Write-Head([string] $Text) {
    Write-Host ''
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('-' * 74) -ForegroundColor DarkCyan
}

function Write-Row([string] $Label, [string] $State, [string] $Detail, [ConsoleColor] $Colour) {
    Write-Host ('  {0,-22}' -f $Label) -NoNewline
    Write-Host ('{0,-11}' -f $State) -ForegroundColor $Colour -NoNewline
    Write-Host $Detail -ForegroundColor DarkGray
}

function Write-Note([string] $Text) { Write-Host "  $Text" -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# ExecutionPolicy self-diagnosis
#
# A run launched with -ExecutionPolicy Bypass makes Get-ExecutionPolicy report Bypass,
# which says nothing about what the next bare invocation will do. The persisted policy
# is what matters: the first non-Undefined value across MachinePolicy, UserPolicy,
# CurrentUser and LocalMachine. When that is restrictive (or Undefined, which on Windows
# client means Restricted), a bare `.\tools\<script>.ps1` in a fresh shell is blocked, so
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
# Resolve the install
# ---------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($GamePath)) {
    if (-not [string]::IsNullOrWhiteSpace($env:KSTP_GAME_PATH)) {
        $GamePath = $env:KSTP_GAME_PATH; $gameSource = 'KSTP_GAME_PATH'
    } else {
        $GamePath = $DefaultGamePath;    $gameSource = 'script default'
    }
} else {
    $gameSource = '-GamePath'
}

Write-Host ''
Write-Host "KSTP environment check $KSTPVersion" -ForegroundColor White

Write-KSTPPolicyHint 'tools\verify-env.ps1'

Write-Head 'Game install'

if (-not (Test-Path -LiteralPath $GamePath -PathType Container)) {
    Write-Row 'directory' 'MISSING' $GamePath Red
    Write-Host ''
    Write-Host "  '$GamePath' does not exist (resolved from $gameSource)." -ForegroundColor Red
    Write-Note 'Pass -GamePath, set KSTP_GAME_PATH, or edit $DefaultGamePath in this script.'
    Write-Host ''
    exit 1
}

$GamePath = (Resolve-Path -LiteralPath $GamePath).ProviderPath.TrimEnd('\')
$gameExe  = Join-Path $GamePath 'bin\x64\Cyberpunk2077.exe'

Write-Row 'directory' 'OK' "$GamePath  (from $gameSource)" Green

if (-not (Test-Path -LiteralPath $gameExe -PathType Leaf)) {
    Write-Row 'Cyberpunk2077.exe' 'MISSING' 'bin\x64\Cyberpunk2077.exe' Red
    Write-Host ''
    Write-Host '  That directory is not a Cyberpunk 2077 install. No further checks are possible.' -ForegroundColor Red
    Write-Host ''
    exit 1
}

$exeInfo    = Get-Item -LiteralPath $gameExe
$exeVersion = $exeInfo.VersionInfo.ProductVersion
if ([string]::IsNullOrWhiteSpace($exeVersion)) { $exeVersion = 'unreported' }
Write-Row 'Cyberpunk2077.exe' 'OK' "product version $exeVersion" Green
Write-Note 'KSTP targets game build 2.31. A different build may move native offsets under the frameworks.'

# ---------------------------------------------------------------------------
# Frameworks
#
# Each entry is identified by a marker file that exists only once the framework is
# installed and working, rather than by the folder its installer creates.
# ---------------------------------------------------------------------------

$frameworks = @(
    [pscustomobject]@{
        Name     = 'redscript'
        Marker   = 'engine\tools\scc.exe'
        Extra    = @('r6\config\cybercmd\scc.toml')
        Required = $true
        Why      = 'compiles every .reds in r6\scripts; KSTP is redscript'
    }
    [pscustomobject]@{
        Name     = 'cybercmd'
        Marker   = 'bin\x64\plugins\cybercmd.asi'
        Extra    = @()
        Required = $true
        Why      = 'launches scc.exe at startup; without it redscript never runs'
    }
    [pscustomobject]@{
        Name     = 'RED4ext'
        Marker   = 'red4ext\RED4ext.dll'
        Extra    = @('bin\x64\winmm.dll')
        Required = $true
        Why      = 'hosts TweakXL / ArchiveXL / Codeware / Mod Settings'
    }
    [pscustomobject]@{
        Name     = 'TweakXL'
        Marker   = 'red4ext\plugins\TweakXL\TweakXL.dll'
        Extra    = @('red4ext\plugins\TweakXL\Scripts')
        Required = $true
        Why      = 'loads r6\tweaks\KSTP, the cyberware and stat records'
    }
    [pscustomobject]@{
        Name     = 'ArchiveXL'
        Marker   = 'red4ext\plugins\ArchiveXL\ArchiveXL.dll'
        Extra    = @('red4ext\plugins\ArchiveXL\Scripts')
        Required = $false
        # KSTP has no .archive and no .xl. Every string it shows is a literal carried on
        # the redscript and TweakXL side, so nothing in the mod loads through ArchiveXL
        # and requiring it would send players after a dependency they do not need.
        Why      = 'loads .xl archive manifests; KSTP ships none, so nothing in the mod depends on it'
    }
    [pscustomobject]@{
        Name     = 'Codeware'
        Marker   = 'red4ext\plugins\Codeware\Codeware.dll'
        Extra    = @('red4ext\plugins\Codeware\Scripts')
        Required = $false
        Why      = 'swaps the NPC-spawn hook to the CallbackSystem path; the vanilla @wrapMethod fallback is equivalent, that hook feeds only the faction axis, and its call surface here is UNVERIFIED (Faction.reds)'
    }
    [pscustomobject]@{
        Name     = 'Mod Settings'
        Marker   = 'red4ext\plugins\mod_settings\mod_settings.dll'
        Extra    = @('red4ext\plugins\mod_settings\module.reds')
        Required = $false
        Why      = 'the only backing store for the experiment gates; without it all three stay off'
    }
    [pscustomobject]@{
        Name     = 'Input Loader'
        Marker   = 'red4ext\plugins\input_loader\input_loader.dll'
        Extra    = @()
        Required = $false
        Why      = 'merges r6\input\*.xml without editing vanilla input files'
    }
    [pscustomobject]@{
        Name     = 'Cyber Engine Tweaks'
        Marker   = 'bin\x64\plugins\cyber_engine_tweaks.asi'
        Extra    = @('bin\x64\plugins\cyber_engine_tweaks\mods')
        Required = $false
        Why      = 'runs the KSTP experiment lab; development only, not needed to play'
    }
)

# Content directories the deploy writes into. These are not frameworks; their absence is
# the usual reason a framework reports as installed yet loads nothing. WhenAbsent carries
# the per-directory meaning: deploy.ps1 creates the ones it writes to, and it never
# touches archive\pc\mod, since KSTP ships no .archive.
$contentDirs = @(
    [pscustomobject]@{ Name = 'r6\scripts';     Path = 'r6\scripts';     Note = 'redscript source root';  WhenAbsent = 'deploy.ps1 will create it' }
    [pscustomobject]@{ Name = 'r6\tweaks';      Path = 'r6\tweaks';      Note = 'TweakXL YAML root';       WhenAbsent = 'deploy.ps1 will create it' }
    [pscustomobject]@{ Name = 'r6\input';       Path = 'r6\input';       Note = 'Input Loader XML root';   WhenAbsent = 'deploy.ps1 will create it' }
    [pscustomobject]@{ Name = 'archive\pc\mod'; Path = 'archive\pc\mod'; Note = 'archive + .xl root';      WhenAbsent = 'expected; KSTP writes nothing here' }
    [pscustomobject]@{ Name = 'CET mods';       Path = 'bin\x64\plugins\cyber_engine_tweaks\mods'; Note = 'CET Lua mod root'; WhenAbsent = 'deploy.ps1 will create it' }
)

Write-Head 'Frameworks'

$missingRequired = New-Object System.Collections.Generic.List[string]
$missingOptional = New-Object System.Collections.Generic.List[string]

foreach ($fw in $frameworks) {
    $markerFull = Join-Path $GamePath $fw.Marker
    $present    = Test-Path -LiteralPath $markerFull

    if ($present) {
        $detail = $fw.Marker
        $absentExtras = @($fw.Extra | Where-Object { -not (Test-Path -LiteralPath (Join-Path $GamePath $_)) })
        if ($absentExtras.Count -gt 0) {
            Write-Row $fw.Name 'PARTIAL' "$detail  (missing: $($absentExtras -join ', '))" Yellow
        } else {
            Write-Row $fw.Name 'INSTALLED' $detail Green
        }
    } else {
        if ($fw.Required) {
            Write-Row $fw.Name 'MISSING' $fw.Why Red
            $missingRequired.Add($fw.Name)
        } else {
            Write-Row $fw.Name 'MISSING' $fw.Why DarkYellow
            $missingOptional.Add($fw.Name)
        }
    }
}

Write-Head 'Content directories'

foreach ($dir in $contentDirs) {
    $full = Join-Path $GamePath $dir.Path
    if (Test-Path -LiteralPath $full -PathType Container) {
        $count = @(Get-ChildItem -LiteralPath $full -Force -ErrorAction SilentlyContinue).Count
        Write-Row $dir.Name 'PRESENT' "$count entr(ies) - $($dir.Note)" Green
    } else {
        # Absence is never fatal here; the meaning is per-directory.
        Write-Row $dir.Name 'ABSENT' "$($dir.Note) - $($dir.WhenAbsent)" DarkYellow
    }
}

# ---------------------------------------------------------------------------
# KSTP deployment state
# ---------------------------------------------------------------------------

Write-Head 'KSTP deployment'

$kstpProbes = @(
    [pscustomobject]@{ Name = 'scripts'; Path = 'r6\scripts\KSTP' }
    [pscustomobject]@{ Name = 'tweaks';  Path = 'r6\tweaks\KSTP' }
    [pscustomobject]@{ Name = 'CET lab'; Path = 'bin\x64\plugins\cyber_engine_tweaks\mods\kstp_lab' }
)

foreach ($probe in $kstpProbes) {
    $full = Join-Path $GamePath $probe.Path
    if (Test-Path -LiteralPath $full -PathType Container) {
        $files = @(Get-ChildItem -LiteralPath $full -Recurse -File -Force -ErrorAction SilentlyContinue)
        $newest = if ($files.Count -gt 0) {
            ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        } else { 'empty' }
        Write-Row $probe.Name 'DEPLOYED' "$($files.Count) file(s), newest $newest" Green
    } else {
        Write-Row $probe.Name 'NOT THERE' $probe.Path DarkYellow
    }
}

$manifestDir = Join-Path $PSScriptRoot '.deploy-manifests'
if (Test-Path -LiteralPath $manifestDir -PathType Container) {
    $manifests = @(Get-ChildItem -LiteralPath $manifestDir -Filter '*.txt' -File -ErrorAction SilentlyContinue)
    Write-Note "deploy manifests: $($manifests.Count) recorded install(s) in tools\.deploy-manifests"
} else {
    Write-Note 'deploy manifests: none; deploy.ps1 has not run from this working copy'
}

# ---------------------------------------------------------------------------
# Logs
#
# Paths hold for a modded 2.31 install. redscript rotates its log per launch and keeps
# the newest as *_rCURRENT.log, which is the one to read.
# ---------------------------------------------------------------------------

Write-Head 'Logs - where errors show up'

$logs = @(
    [pscustomobject]@{
        Name = 'redscript compile'
        Path = 'r6\logs\redscript_rCURRENT.log'
        Note = 'Read this first. Every .reds syntax or type error and every unresolved symbol.'
    }
    [pscustomobject]@{
        Name = 'cybercmd'
        Path = 'r6\logs\cybercmd_rCURRENT.log'
        Note = 'Whether scc.exe was launched. An empty redscript log usually means this step failed.'
    }
    [pscustomobject]@{
        Name = 'RED4ext'
        Path = 'red4ext\logs'
        Note = 'red4ext-<timestamp>.log plus one log per plugin (TweakXL, ArchiveXL, Codeware).'
    }
    [pscustomobject]@{
        Name = 'CET'
        Path = 'bin\x64\plugins\cyber_engine_tweaks\cyber_engine_tweaks.log'
        Note = 'CET startup and mod load. Lua runtime errors go to scripting.log next to it.'
    }
    [pscustomobject]@{
        Name = 'CET scripting'
        Path = 'bin\x64\plugins\cyber_engine_tweaks\scripting.log'
        Note = 'Lua errors from the KSTP experiment lab.'
    }
    [pscustomobject]@{
        Name = 'game log'
        Path = 'bin\x64\plugins\cyber_engine_tweaks\gamelog.log'
        Note = 'FTLog / ModLog output from redscript, captured by CET when CET is installed.'
    }
)

foreach ($log in $logs) {
    $full = Join-Path $GamePath $log.Path
    if (Test-Path -LiteralPath $full) {
        $item = Get-Item -LiteralPath $full
        $when = $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        Write-Row $log.Name 'EXISTS' "last written $when" Green
    } else {
        Write-Row $log.Name 'NOT YET' 'appears after the next game launch' DarkYellow
    }
    Write-Host "                          $full" -ForegroundColor DarkGray
    Write-Host "                          $($log.Note)" -ForegroundColor DarkGray
}

$redscriptLog = Join-Path $GamePath 'r6\logs\redscript_rCURRENT.log'
Write-Host ''
Write-Host '  Redscript compile log:' -ForegroundColor White
Write-Host "    $redscriptLog" -ForegroundColor White
Write-Note 'Tail it after a launch:'
Write-Note "  Get-Content -Wait -Tail 60 '$redscriptLog'"
Write-Note 'Find KSTP errors:'
Write-Note "  Select-String -Path '$redscriptLog' -Pattern 'ERROR','KSTP'"

if (Test-Path -LiteralPath (Join-Path $GamePath 'r6\logs')) {
    $rotated = @(Get-ChildItem -LiteralPath (Join-Path $GamePath 'r6\logs') -Filter 'redscript_r*.log' -File -ErrorAction SilentlyContinue)
    if ($rotated.Count -gt 1) {
        Write-Note "($($rotated.Count) redscript logs present; the timestamped ones are previous launches.)"
    }
}

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------

Write-Head 'Verdict'

if ($missingRequired.Count -eq 0) {
    Write-Host '  All required frameworks are installed. KSTP can load here.' -ForegroundColor Green
} else {
    Write-Host "  MISSING REQUIRED: $($missingRequired -join ', ')" -ForegroundColor Red
    Write-Note 'KSTP will not load until these are installed.'
}

if ($missingOptional.Count -gt 0) {
    Write-Host "  Missing optional : $($missingOptional -join ', ')" -ForegroundColor DarkYellow
    Write-Note 'KSTP still runs; the features these back degrade to defaults.'
    if ($missingOptional -contains 'Cyber Engine Tweaks') {
        Write-Note 'Without CET the five experiments in experiments\cet\kstp_lab\README.md cannot be run,'
        Write-Note 'so every gate in Mod Settings stays off. The mod is fully playable in that state.'
    }
}

# Mod Settings stays Required = $false because KSTP loads without it: Core/Gate.reds
# compiles and runs with the framework absent, every gate reading its compiled default
# of false, and the mod is fully playable in that state. Failing -Strict on it would
# send players after a dependency the mod does not need to run.
#
# It is still the only backing store for the three experiment gates. Gate.reds reads
# them through @runtimeProperty("ModSettings.*") alone: no console command, no config
# file, no fallback. Without the framework the experiments in
# experiments\cet\kstp_lab\README.md can be run but their results cannot be recorded, so
# the block below states that separately from the generic optional-framework line.
if ($missingOptional -contains 'Mod Settings') {
    Write-Host ''
    Write-Host '  EXPERIMENT GATES ----------------------------------------------------' -ForegroundColor Yellow
    Write-Host '  Mod Settings is required to record an experiment result.' -ForegroundColor Yellow
    Write-Host '  Without it every gate stays off.' -ForegroundColor Yellow
    Write-Note 'KSTP loads and plays; body-part policy and the IFF HUD need no gate.'
    Write-Note 'E-STAT, E-TRACK and E-IGNORE have no other backing store: Core\Gate.reds'
    Write-Note 'reads all three from Mod Settings alone. No console command, no config file.'
    Write-Note 'Install it before working through experiments\cet\kstp_lab\README.md, or the'
    Write-Note 'results are unrecordable and the faction axis cannot be switched on.'
    Write-Host '  ---------------------------------------------------------------------' -ForegroundColor Yellow
}

Write-Host ''

if ($Strict -and $missingRequired.Count -gt 0) { exit 1 }
exit 0
