#requires -Version 5.1
<#
.SYNOPSIS
    Prepares the selected macOS Recovery payload using the persistent verified cache.
.DESCRIPTION
    This pipeline wrapper keeps the public stage contract stable while delegating
    implementation to download-recovery-impl.ps1. The implementation stores the
    Recovery payload outside the repository and reuses it only after SHA/chunk
    validation succeeds.
#>
[CmdletBinding()]
param(
    [switch]$Latest,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$totalSteps = 8

$implementation = Join-Path $PSScriptRoot 'download-recovery-impl.ps1'
if (-not (Test-Path -LiteralPath $implementation -PathType Leaf)) {
    Write-Error "Recovery implementation was not found: $implementation"
    exit 4
}

$arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$implementation)
if ($Latest) { $arguments += '-Latest' }
if ($Force) { $arguments += '-Force' }

& powershell.exe @arguments
exit ([int]$LASTEXITCODE)
