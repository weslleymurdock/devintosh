#requires -Version 5.1
<#
.SYNOPSIS
    Applies matched declarative OpenCore profile fragments.

.DESCRIPTION
    Compatibility entry point. The implementation lives in apply-opencore-profiles-fixed.ps1.
    Keeping this wrapper preserves the expected command name without duplicating the engine.
#>

& (Join-Path $PSScriptRoot 'apply-opencore-profiles-fixed.ps1') @args
exit $LASTEXITCODE
