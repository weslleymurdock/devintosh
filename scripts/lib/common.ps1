#requires -Version 5.1
<#
.SYNOPSIS
    Shared runtime helpers for Devintosh PowerShell scripts.

.DESCRIPTION
    Establishes en-US culture, common exit codes, paths, strict-mode defaults,
    and safe cleanup/error handling used by the preparation pipeline.

.EXIT CODES
    0 = Success.
    1 = General failure.
    2 = Validation failure.
    3 = Insufficient privileges.
    4 = Target device or resource not found.
    5 = Backup or rollback failure.
    6 = External dependency failure.
    7 = Asset integrity failure.
    8 = Unsupported hardware or configuration.
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

$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:BuildRoot = Join-Path $script:RepoRoot 'build'
$script:LogRoot = Join-Path $script:RepoRoot 'logs'
$script:BackupRoot = Join-Path $script:BuildRoot 'backups'

function Initialize-DevintoshRuntime {
    foreach ($path in @($script:BuildRoot, $script:LogRoot, $script:BackupRoot)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
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

    try {
        & $Action
        return $script:EXIT_SUCCESS
    } catch {
        Write-Host "[$(Get-Timestamp)] ERROR: $($_.Exception.Message)"
        try {
            & $Rollback
            return $FailureExitCode
        } catch {
            Write-Host "[$(Get-Timestamp)] ERROR: Automatic rollback failed: $($_.Exception.Message)"
            return $script:EXIT_ROLLBACK_FAILURE
        }
    }
}

Initialize-DevintoshRuntime
