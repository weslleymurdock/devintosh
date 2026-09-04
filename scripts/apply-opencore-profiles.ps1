#requires -Version 5.1
<#
.SYNOPSIS
    Applies matched declarative OpenCore profile fragments.

.DESCRIPTION
    Compatibility entry point. The implementation lives in apply-opencore-profiles-fixed.ps1.
    Keeping this wrapper preserves the expected command name without duplicating the engine.

.NOTES
    Declares the stage step count so main.ps1 can build the global pipeline step plan
    without executing the implementation during preflight.
#>

$step = 0
$totalSteps = 7

& (Join-Path $PSScriptRoot 'apply-opencore-profiles-fixed.ps1') @args
exit $LASTEXITCODE
