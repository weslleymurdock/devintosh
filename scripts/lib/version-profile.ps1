#requires -Version 5.1
<#
.SYNOPSIS
    Loads the selected macOS target profile and its pinned OpenCore version.
.DESCRIPTION
    Version-specific data lives under config/versions/<id>.json. The selected target
    is propagated by main.ps1 through DEVINTOSH_MACOS_VERSION so every isolated stage
    consumes the same OS/OpenCore contract. A stage must never hardcode an OpenCore
    version or a macOS release when the value belongs to the target profile.
#>
Set-StrictMode -Version Latest

function Get-DevintoshMacOSVersionId {
    $value = [string]$env:DEVINTOSH_MACOS_VERSION
    if ([string]::IsNullOrWhiteSpace($value)) { return 'sequoia' }
    return $value.Trim().ToLowerInvariant()
}

function Get-DevintoshVersionProfile {
    param([string]$VersionId = (Get-DevintoshMacOSVersionId))

    if ([string]::IsNullOrWhiteSpace($VersionId)) {
        throw 'macOS target version identifier cannot be empty.'
    }

    $normalizedId = $VersionId.Trim().ToLowerInvariant()
    if ($normalizedId -notmatch '^[a-z0-9][a-z0-9.-]*$') {
        throw "Invalid macOS target version identifier: $VersionId"
    }

    $path = Join-Path $script:RepoRoot ("config\versions\{0}.json" -f $normalizedId)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "macOS target profile '$normalizedId' was not found: $path"
    }

    try {
        $profile = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "Failed to parse macOS target profile '$path': $($_.Exception.Message)"
    }

    $profileId = [string]$profile.id
    $family = [string]$profile.macOSFamily
    $major = [int]$profile.macOSMajorVersion
    $oc = $profile.opencore
    $ocVersion = [string]$oc.version
    $ocTag = [string]$oc.tag
    $ocUrl = [string]$oc.releaseUrl
    $ocSha = ([string]$oc.releaseSha256).ToLowerInvariant()
    $ocCommit = [string]$oc.pinnedCommit

    if ($profileId -ne $normalizedId) { throw "Version profile id mismatch: file '$normalizedId' declares '$profileId'." }
    if ([string]::IsNullOrWhiteSpace($family) -or $major -le 0) { throw "Version profile '$normalizedId' has an invalid macOS identity." }
    if ([string]::IsNullOrWhiteSpace($ocVersion) -or [string]::IsNullOrWhiteSpace($ocTag) -or [string]::IsNullOrWhiteSpace($ocUrl) -or $ocSha -notmatch '^[0-9a-f]{64}$') { throw "Version profile '$normalizedId' has an incomplete OpenCore release pin." }
    if ([string]::IsNullOrWhiteSpace($ocCommit)) { throw "Version profile '$normalizedId' must pin the OpenCore source commit used by version-sensitive tooling." }

    return $profile
}

function Get-DevintoshOpenCoreProfile {
    $profile = Get-DevintoshVersionProfile
    return $profile.opencore
}
