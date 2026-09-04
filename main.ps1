#requires -Version 5.1
<#
.SYNOPSIS
    Runs the complete Devintosh build pipeline from a clean clone.
.DESCRIPTION
    Executes each pipeline stage in an isolated Windows PowerShell 5.1 child process.
    A non-zero exit code stops the pipeline immediately; later stages are never run
    after a failure. The final stage invokes prepare-boot-disk.ps1 without a disk
    number so disk selection remains interactive and hardware-agnostic.

    This orchestrator does not select, clean, partition, or format a disk itself.
    The destructive disk stage remains the final interactive operation and retains
    its own Windows-disk safety checks and typed confirmation.
.PARAMETER Force
    Pass -Force to every pipeline stage that supports it.
#>
[CmdletBinding()]
param([switch]$Force)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repoRoot=$PSScriptRoot
$scriptRoot=Join-Path $repoRoot 'scripts'
function Invoke-PipelineStep {
    param([Parameter(Mandatory=$true)][string]$ScriptName)
    $path=Join-Path $scriptRoot $ScriptName
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Pipeline script not found: $path"}
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$path)
    if($Force){$arguments+='-Force'}
    Write-Host ''
    Write-Host ("[MAIN] Starting {0}" -f $ScriptName)
    & powershell.exe @arguments
    $code=[int]$LASTEXITCODE
    if($code -ne 0){Write-Host ("[MAIN] STOP: {0} failed with exit code {1}. No subsequent pipeline stage will run." -f $ScriptName,$code);exit $code}
    Write-Host ("[MAIN] Completed {0} successfully." -f $ScriptName)
}
try {
    if(-not(Test-Path -LiteralPath (Join-Path $repoRoot '.git') -PathType Container)){throw 'main.ps1 must be executed from a clean cloned Devintosh repository.'}
    $requiredScripts=@('validate.ps1','prepare.ps1','download-recovery.ps1','build-opencore.ps1','configure-opencore-hardware.ps1','configure-opencore.ps1','acquire-opencore-drivers.ps1','resolve-gpu.ps1','apply-opencore-profiles.ps1','resolve-smbios.ps1','bootstrap-smbios.ps1','configure-first-boot.ps1','resolve-acpi.ps1','resolve-usb.ps1','resolve-network.ps1','resolve-audio.ps1','resolve-kexts.ps1','acquire-kext-assets.ps1','compose-opencore-kexts.ps1','validate-opencore.ps1','readiness.ps1','prepare-boot-disk.ps1')
    foreach($scriptName in $requiredScripts){if(-not(Test-Path -LiteralPath (Join-Path $scriptRoot $scriptName) -PathType Leaf)){throw "Required pipeline stage is missing: $scriptName"}}
    Write-Host '';Write-Host '============================================================';Write-Host 'DEVINTOSH - COMPLETE CLEAN-CLONE PIPELINE';Write-Host '============================================================';Write-Host 'Every stage is isolated and checked by exit code.';Write-Host 'The pipeline stops immediately on the first failure.';Write-Host 'Disk preparation is the final interactive stage.';Write-Host '============================================================'
    foreach($scriptName in $requiredScripts){if($scriptName -eq 'prepare-boot-disk.ps1'){Write-Host '';Write-Host '[MAIN] Reaching final disk setup. Disk selection remains interactive.'};Invoke-PipelineStep -ScriptName $scriptName}
    Write-Host '';Write-Host '[MAIN] COMPLETE: all Devintosh pipeline stages succeeded.';exit 0
}catch{Write-Host ("[MAIN] STOP: {0}" -f $_.Exception.Message);exit 1}
