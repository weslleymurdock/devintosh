#requires -Version 5.1
<#
.SYNOPSIS
    Applies matched declarative OpenCore profile fragments.
.DESCRIPTION
    Compatibility entry point. The implementation lives in apply-opencore-profiles-fixed.ps1.
    Keeping this wrapper preserves the expected command name without duplicating the engine.

    The wrapper explicitly forwards the bound -Force switch to the implementation.
    This is required because named parameters bound by an advanced script are not
    automatically present in the automatic $args collection.

.NOTES
    Declares the stage step count so main.ps1 can build the global pipeline step plan
    without executing the implementation during preflight.
#>

[CmdletBinding()]
param(
    [switch]$Force
)

$step = 0
$totalSteps = 7

if ($Force) {
    & (Join-Path $PSScriptRoot 'apply-opencore-profiles-fixed.ps1') -Force
} else {
    & (Join-Path $PSScriptRoot 'apply-opencore-profiles-fixed.ps1')
}

exit $LASTEXITCODE
