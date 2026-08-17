# ---------------------------------------------------------------------------
# HOW TO RUN THIS
#
#   powershell -ExecutionPolicy Bypass -File .\tools\watch.ps1
#
# A bare `.\tools\watch.ps1` fails on a default Windows 11 box: the client
# default ExecutionPolicy is Restricted, which blocks every .ps1. The form above
# works regardless of policy and changes no machine-wide setting. Arguments go
# after the script path:
#
#   powershell -ExecutionPolicy Bypass -File .\tools\watch.ps1 -DebounceMs 1000
#
# Bypass applies to the whole process, so the deploy.ps1 this script invokes
# inherits it and needs no separate handling.
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Re-runs tools\deploy.ps1 whenever a deployable source file changes.

.DESCRIPTION
    Watches src\ and experiments\cet\ with FileSystemWatcher. Changes are coalesced
    over a short debounce window, so a multi-file save or a git checkout triggers
    one deploy rather than one per file.

    Redscript compiles at game launch, so a deploy while the game is running takes
    effect at the next launch. The watcher keeps the install in sync with the source
    tree so that launching is the only remaining step.

    Ctrl+C stops the watcher and releases its event subscriptions.

.PARAMETER GamePath
    Passed straight through to deploy.ps1, which resolves the install from
    -GamePath, then $env:KSTP_GAME_PATH, then its own $DefaultGamePath.

.PARAMETER DebounceMs
    Quiet period after the last change before deploying. Default 500 ms.

.PARAMETER NoInitialDeploy
    Skip the deploy that otherwise runs once at startup.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\watch.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\watch.ps1 -GamePath 'D:\Games\Cyberpunk 2077' -DebounceMs 1000

.NOTES
    KSTP tools version 1.0.0.
#>
[CmdletBinding()]
param(
    [string] $GamePath,
    [int]    $DebounceMs = 500,
    [switch] $NoInitialDeploy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Version reported in the banner line below.
$KSTPVersion  = '1.0.0'

$ProjectRoot  = Split-Path -Parent $PSScriptRoot
$DeployScript = Join-Path $PSScriptRoot 'deploy.ps1'

if (-not (Test-Path -LiteralPath $DeployScript -PathType Leaf)) {
    throw "deploy.ps1 not found next to watch.ps1 (looked in '$PSScriptRoot')."
}

# ---------------------------------------------------------------------------
# ExecutionPolicy self-diagnosis
#
# A run launched with -ExecutionPolicy Bypass makes Get-ExecutionPolicy report Bypass,
# which says nothing about what the next bare invocation will do. The persisted policy
# is what matters: the first non-Undefined value across MachinePolicy, UserPolicy,
# CurrentUser and LocalMachine. When that is restrictive (or Undefined, which on Windows
# client means Restricted), a bare `.\tools\watch.ps1` in a fresh shell is blocked, so
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
    Write-Host '  That is per-process only; it changes no machine-wide setting.' -ForegroundColor DarkGray
}

Write-KSTPPolicyHint 'tools\watch.ps1'

Write-Host ''
Write-Host "KSTP watch $KSTPVersion" -ForegroundColor White

$WatchRoots = @(
    (Join-Path $ProjectRoot 'src'),
    (Join-Path $ProjectRoot 'experiments\cet')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Container }

if ($WatchRoots.Count -eq 0) {
    throw "Nothing to watch: neither 'src' nor 'experiments\cet' exists under '$ProjectRoot'."
}

# The extensions that trigger a redeploy. deploy.ps1 copies every file in a mapped tree that
# is not an editor dropping, so a change to any other type - the lab's README.md, for one -
# waits for the next deploy rather than starting one.
$WatchExtensions = @('.reds', '.lua', '.yaml', '.yml', '.xl', '.xml', '.json', '.archive', '.toml', '.txt')
$IgnoreFragments = @('\.git\', '\node_modules\', '\.vs\', '\.idea\')

function Test-Relevant([string] $Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    foreach ($fragment in $IgnoreFragments) {
        if ($Path -like "*$fragment*") { return $false }
    }
    $name = Split-Path -Leaf $Path
    # Editors write sentinel and swap files constantly. None of them are deployable.
    if ($name -like '*~' -or $name -like '*.tmp' -or $name -like '*.swp' -or $name -eq '4913') { return $false }

    $ext = [System.IO.Path]::GetExtension($Path)
    if ([string]::IsNullOrEmpty($ext)) {
        # A directory create/rename has no extension. Treat it as relevant so new
        # module folders get picked up.
        return -not (Test-Path -LiteralPath $Path -PathType Leaf)
    }
    return $WatchExtensions -contains $ext.ToLowerInvariant()
}

function Get-DisplayPath([string] $Path) {
    $prefix = $ProjectRoot.TrimEnd('\') + '\'
    if ($Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring($prefix.Length)
    }
    return $Path
}

function Invoke-Deploy([string] $Reason) {
    Write-Host ''
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Reason) -ForegroundColor Magenta
    try {
        $deployArgs = @{ Quiet = $true }
        if (-not [string]::IsNullOrWhiteSpace($GamePath)) { $deployArgs['GamePath'] = $GamePath }
        & $DeployScript @deployArgs
    } catch {
        # A failed deploy must not stop the watcher. The next save retries.
        Write-Host "  DEPLOY FAILED: $($_.Exception.Message)" -ForegroundColor Red
    }
}

$watchers      = New-Object System.Collections.Generic.List[System.IO.FileSystemWatcher]
$subscriptions = New-Object System.Collections.Generic.List[string]

try {
    $index = 0
    foreach ($root in $WatchRoots) {
        $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
        $watcher = New-Object System.IO.FileSystemWatcher
        $watcher.Path                  = $resolved
        $watcher.IncludeSubdirectories = $true
        $watcher.NotifyFilter          = [System.IO.NotifyFilters]::FileName -bor
                                         [System.IO.NotifyFilters]::DirectoryName -bor
                                         [System.IO.NotifyFilters]::LastWrite
        $watcher.EnableRaisingEvents   = $true
        $watchers.Add($watcher)

        foreach ($eventName in @('Created', 'Changed', 'Deleted', 'Renamed')) {
            $sourceId = "KSTPWatch_${index}_$eventName"
            Register-ObjectEvent -InputObject $watcher -EventName $eventName -SourceIdentifier $sourceId | Out-Null
            $subscriptions.Add($sourceId)
        }
        $index++

        Write-Host "watching  $resolved" -ForegroundColor DarkGray
    }

    Write-Host ("debounce  {0} ms" -f $DebounceMs) -ForegroundColor DarkGray
    Write-Host 'Ctrl+C to stop.' -ForegroundColor DarkGray

    if (-not $NoInitialDeploy) { Invoke-Deploy 'initial deploy' }

    while ($true) {
        $pending = Wait-Event -Timeout 1
        if ($null -eq $pending) { continue }

        # Drain the queue, then keep draining until the tree stays quiet for the
        # debounce window. One save burst produces one deploy.
        $changed = New-Object System.Collections.Generic.HashSet[string]
        do {
            foreach ($queued in @(Get-Event)) {
                if ($queued.SourceIdentifier -like 'KSTPWatch_*') {
                    $path = $queued.SourceEventArgs.FullPath
                    if (Test-Relevant $path) { [void]$changed.Add($path) }
                }
                Remove-Event -EventIdentifier $queued.EventIdentifier
            }
            Start-Sleep -Milliseconds $DebounceMs
            $stillBusy = @(Get-Event | Where-Object { $_.SourceIdentifier -like 'KSTPWatch_*' }).Count -gt 0
        } while ($stillBusy)

        if ($changed.Count -eq 0) { continue }

        $label  = Get-DisplayPath (@($changed) | Select-Object -First 1)
        $reason = if ($changed.Count -eq 1) { "changed: $label" } else { "changed: $label (+$($changed.Count - 1) more)" }
        Invoke-Deploy $reason
    }
} finally {
    foreach ($sourceId in $subscriptions) {
        Unregister-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue
    }
    foreach ($watcher in $watchers) {
        $watcher.EnableRaisingEvents = $false
        $watcher.Dispose()
    }
    Get-Event | Where-Object { $_.SourceIdentifier -like 'KSTPWatch_*' } |
        ForEach-Object { Remove-Event -EventIdentifier $_.EventIdentifier }
    Write-Host ''
    Write-Host 'watcher stopped.' -ForegroundColor DarkGray
}
