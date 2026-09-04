#requires -Version 5.1
<#
.SYNOPSIS
    Shared runtime helpers and the central Devintosh project contract.
.DESCRIPTION
    Establishes en-US culture, common exit codes, and loads project-context.ps1.
    Every pipeline stage MUST source this library. project-context.ps1 then exposes
    the authoritative $script:Devintosh object containing repository paths, the
    selected macOS profile, its OpenCore pin, its Recovery pin, generated artifact
    locations, and the persistent Recovery cache path.

    Scripts must not independently reconstruct these values. This prevents producer
    and consumer stages from silently disagreeing about paths, versions, or pins.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
    [System.Threading.Thread]::CurrentThread.CurrentUICulture = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
} catch { }

$script:EXIT_SUCCESS = 0
$script:EXIT_GENERAL_FAILURE = 1
$script:EXIT_VALIDATION_FAILURE = 2
$script:EXIT_INSUFFICIENT_PRIVILEGES = 3
$script:EXIT_TARGET_NOT_FOUND = 4
$script:EXIT_ROLLBACK_FAILURE = 5
$script:EXIT_DEPENDENCY_FAILURE = 6
$script:EXIT_ASSET_INTEGRITY_FAILURE = 7
$script:EXIT_UNSUPPORTED_CONFIGURATION = 8
$script:EXIT_BLOCKING_WARNING = 9

$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:BuildRoot = Join-Path $script:RepoRoot 'build'
$script:LogRoot = Join-Path $script:RepoRoot 'logs'
$script:BackupRoot = Join-Path $script:BuildRoot 'backups'

$contextPath = Join-Path $PSScriptRoot 'project-context.ps1'
if (-not (Test-Path -LiteralPath $contextPath -PathType Leaf)) { throw "Required shared project context was not found: $contextPath" }
. $contextPath

function Initialize-DevintoshRuntime {
    foreach ($path in @($script:BuildRoot, $script:LogRoot, $script:BackupRoot)) {
        if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Timestamp {
    return (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::GetCultureInfo('en-US'))
}

function Invoke-Safely {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][scriptblock]$Rollback,
        [int]$FailureExitCode = $script:EXIT_GENERAL_FAILURE
    )
    try { & $Action; return $script:EXIT_SUCCESS }
    catch {
        Write-Host "[$(Get-Timestamp)] ERROR: $($_.Exception.Message)"
        try { & $Rollback; return $FailureExitCode }
        catch { Write-Host "[$(Get-Timestamp)] ERROR: Automatic rollback failed: $($_.Exception.Message)"; return $script:EXIT_ROLLBACK_FAILURE }
    }
}

Initialize-DevintoshRuntime
