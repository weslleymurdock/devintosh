#requires -Version 5.1
<#
.SYNOPSIS
    Runs the complete Devintosh build pipeline from a clean clone.
.DESCRIPTION
    Executes every non-destructive preparation and OpenCore generation stage in
    an isolated Windows PowerShell 5.1 child process. A non-zero exit code stops
    the pipeline immediately; later stages are never run.

    The final prepare-boot-disk.ps1 stage is intentionally invoked without a
    target disk number and without -Force. It therefore presents the available
    physical disks for interactive selection and retains all destructive safety
    confirmations. No later pipeline stage exists after disk preparation.

.PARAMETER Force
    Passes -Force to non-destructive pipeline stages. It never bypasses the
    active Windows disk protection or the final destructive disk confirmation.
#>
[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = $PSScriptRoot
$scriptRoot = Join-Path $repoRoot 'scripts'

$pipeline = @(
    'validate.ps1'
    'prepare.ps1'
    'download-recovery.ps1'
    'build-opencore.ps1'
    'configure-opencore-hardware.ps1'
    'configure-opencore.ps1'
    'acquire-opencore-drivers.ps1'
    'resolve-gpu.ps1'
    'apply-opencore-profiles.ps1'
    'resolve-smbios.ps1'
    'bootstrap-smbios.ps1'
    'configure-first-boot.ps1'
    'resolve-acpi.ps1'
    'resolve-usb.ps1'
    'resolve-network.ps1'
    'resolve-audio.ps1'
    'resolve-kexts.ps1'
    'acquire-kext-assets.ps1'
    'compose-opencore-kexts.ps1'
    'validate-opencore.ps1'
    'readiness.ps1'
)

function Invoke-PipelineStep {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptName,
        [switch]$PassForce
    )

    $path = Join-Path $scriptRoot $ScriptName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Pipeline script not found: $path"
    }

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $path)
    if ($PassForce) {
        $arguments += '-Force'
    }

    Write-Host ''
    Write-Host ("[MAIN] Starting {0}" -f $ScriptName)
    & powershell.exe @arguments
    $code = [int]$LASTEXITCODE

    if ($code -ne 0) {
        Write-Host ("[MAIN] STOP: {0} failed with exit code {1}. No subsequent pipeline stage will run." -f $ScriptName, $code)
        exit $code
    }

    Write-Host ("[MAIN] Completed {0} successfully." -f $ScriptName)
}

try {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot '.git') -PathType Container)) {
        throw 'main.ps1 must be executed from the root of a clean cloned Devintosh repository.'
    }

    $buildRoot = Join-Path $repoRoot 'build'
    if (Test-Path -LiteralPath $buildRoot -PathType Container) {
        $buildEntries = @(Get-ChildItem -LiteralPath $buildRoot -Force -ErrorAction SilentlyContinue)
        if ($buildEntries.Count -gt 0) {
            throw 'The repository is not in a clean build state. Remove the build directory and rerun main.ps1 from a clean clone.'
        }
    }

    foreach ($scriptName in $pipeline) {
        if (-not (Test-Path -LiteralPath (Join-Path $scriptRoot $scriptName) -PathType Leaf)) {
            throw "Required pipeline stage is missing: $scriptName"
        }
    }

    Write-Host ''
    Write-Host '============================================================'
    Write-Host 'DEVINTOSH - COMPLETE CLEAN-CLONE PIPELINE'
    Write-Host '============================================================'
    Write-Host 'Every stage runs in an isolated PowerShell 5.1 process.'
    Write-Host 'The pipeline stops immediately on the first non-zero exit code.'
    Write-Host 'No stage after a failure is executed.'
    Write-Host 'Disk preparation is intentionally the final interactive stage.'
    Write-Host '============================================================'

    foreach ($scriptName in $pipeline) {
        Invoke-PipelineStep -ScriptName $scriptName -PassForce:$Force
    }

    Write-Host ''
    Write-Host '[MAIN] Reaching final disk setup.'
    Write-Host '[MAIN] The available physical disks will now be displayed for interactive selection.'
    Write-Host '[MAIN] No target disk is supplied automatically.'
    Write-Host ''

    # Deliberately do not pass -Force to the destructive disk stage.
    Invoke-PipelineStep -ScriptName 'prepare-boot-disk.ps1'

    Write-Host ''
    Write-Host '[MAIN] COMPLETE: all Devintosh pipeline stages succeeded.'
    exit 0
}
catch {
    Write-Host ("[MAIN] STOP: {0}" -f $_.Exception.Message)
    exit 1
}
