#requires -Version 5.1
<#
.SYNOPSIS
    Loads the selected macOS target profile and its pinned OpenCore/Recovery contract.
.DESCRIPTION
    Version-specific data lives under config/versions/<id>.json. The selected target
    is propagated through DEVINTOSH_MACOS_VERSION so every isolated stage consumes the
    same OS/OpenCore/Recovery contract. Version-sensitive scripts must never hardcode
    a macOS release, OpenCore version, release digest, or Recovery integrity pin.
#>
Set-StrictMode -Version Latest

function Get-DevintoshMacOSVersionId {
    $value = [string]$env:DEVINTOSH_MACOS_VERSION
    if ([string]::IsNullOrWhiteSpace($value)) { return 'sequoia' }
    return $value.Trim().ToLowerInvariant()
}

function Get-DevintoshVersionProfile {
    param([string]$VersionId = (Get-DevintoshMacOSVersionId))

    if ([string]::IsNullOrWhiteSpace($VersionId)) { throw 'macOS target version identifier cannot be empty.' }
    $normalizedId = $VersionId.Trim().ToLowerInvariant()
    if ($normalizedId -notmatch '^[a-z0-9][a-z0-9.-]*$') { throw "Invalid macOS target version identifier: $VersionId" }

    $path = Join-Path $script:RepoRoot ("config\versions\{0}.json" -f $normalizedId)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "macOS target profile '$normalizedId' was not found: $path" }

    try { $profile = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw "Failed to parse macOS target profile '$path': $($_.Exception.Message)" }

    $profileId = [string]$profile.id
    $family = [string]$profile.macOSFamily
    $major = [int]$profile.macOSMajorVersion
    $oc = $profile.opencore
    $ocVersion = [string]$oc.version
    $ocTag = [string]$oc.tag
    $ocUrl = [string]$oc.releaseUrl
    $ocSha = ([string]$oc.releaseSha256).ToLowerInvariant()
    $ocCommit = [string]$oc.pinnedCommit
    $recovery = $profile.recovery
    $chunkSha = ([string]$recovery.chunklistSha256).ToLowerInvariant()

    if ($profileId -ne $normalizedId) { throw "Version profile id mismatch: file '$normalizedId' declares '$profileId'." }
    if ([string]::IsNullOrWhiteSpace($family) -or $major -le 0) { throw "Version profile '$normalizedId' has an invalid macOS identity." }
    if ([string]::IsNullOrWhiteSpace($ocVersion) -or [string]::IsNullOrWhiteSpace($ocTag) -or [string]::IsNullOrWhiteSpace($ocUrl) -or $ocSha -notmatch '^[0-9a-f]{64}$') { throw "Version profile '$normalizedId' has an incomplete OpenCore release pin." }
    if ([string]::IsNullOrWhiteSpace($ocCommit)) { throw "Version profile '$normalizedId' must pin the OpenCore source commit used by version-sensitive tooling." }
    if ([string]::IsNullOrWhiteSpace([string]$recovery.boardId) -or $chunkSha -notmatch '^[0-9a-f]{64}$') { throw "Version profile '$normalizedId' has an incomplete Recovery integrity pin." }

    return $profile
}

function Get-DevintoshOpenCoreProfile {
    $profile = Get-DevintoshVersionProfile
    return $profile.opencore
}
