#requires -Version 5.1
<#
.SYNOPSIS
    Compatibility accessors for the centralized Devintosh project contract.
.DESCRIPTION
    project-context.ps1 is now the single source of truth. These functions remain
    available to existing stages so contributors can migrate incrementally without
    duplicating profile parsing. They return values from $script:Devintosh.
#>
Set-StrictMode -Version Latest

function Get-DevintoshMacOSVersionId {
    return [string]$script:Devintosh.Version.Id
}

function Get-DevintoshVersionProfile {
    return $script:Devintosh.Version.Profile
}

function Get-DevintoshOpenCoreProfile {
    return $script:Devintosh.Version.Profile.opencore
}
