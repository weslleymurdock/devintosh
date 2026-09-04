#requires -Version 5.1
<#
.SYNOPSIS
    Defines the single shared runtime contract for every Devintosh stage.
.DESCRIPTION
    This file is the authoritative source for repository paths, selected target
    profile, OpenCore pin, Recovery pin, generated artifact locations, and the
    persistent Recovery cache location.

    Every pipeline script MUST dot-source common.ps1. common.ps1 loads this file,
    so scripts receive the same $script:Devintosh context without independently
    reconstructing paths or version-specific values.

    The selected target is controlled by DEVINTOSH_MACOS_VERSION. main.ps1 sets it
    before launching child stages; direct stage execution defaults to the current
    supported target defined by the profile loader.

    DEVINTOSH_RECOVERY_CACHE is deliberately outside the repository. Its value is
    derived from the root of the drive containing the repository clone, e.g.
    E:\dev\devintosh -> E:\DevintoshRecoveryCache.
#>
Set-StrictMode -Version Latest

function Initialize-DevintoshProjectContext {
    param([string]$VersionId)

    if ([string]::IsNullOrWhiteSpace($VersionId)) {
        $VersionId = [string]$env:DEVINTOSH_MACOS_VERSION
    }
    if ([string]::IsNullOrWhiteSpace($VersionId)) { $VersionId = 'sequoia' }
    $VersionId = $VersionId.Trim().ToLowerInvariant()

    $profilePath = Join-Path $script:RepoRoot ("config\versions\{0}.json" -f $VersionId)
    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
        throw "macOS target profile '$VersionId' was not found: $profilePath"
    }

    try { $profile = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw "Failed to parse macOS target profile '$profilePath': $($_.Exception.Message)" }

    if ([string]$profile.id -ne $VersionId) { throw "macOS target profile id mismatch: expected '$VersionId', found '$($profile.id)'." }
    if ([string]::IsNullOrWhiteSpace([string]$profile.macOSFamily) -or [int]$profile.macOSMajorVersion -le 0) { throw "Invalid macOS identity in profile '$VersionId'." }
    if ($null -eq $profile.opencore -or $null -eq $profile.recovery) { throw "Profile '$VersionId' must define both OpenCore and Recovery contracts." }

    $oc = $profile.opencore
    $recovery = $profile.recovery
    $ocSha = ([string]$oc.releaseSha256).ToLowerInvariant()
    $chunkSha = ([string]$recovery.chunklistSha256).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace([string]$oc.version) -or [string]::IsNullOrWhiteSpace([string]$oc.tag) -or [string]::IsNullOrWhiteSpace([string]$oc.releaseUrl) -or $ocSha -notmatch '^[0-9a-f]{64}$' -or [string]::IsNullOrWhiteSpace([string]$oc.pinnedCommit)) { throw "OpenCore contract in profile '$VersionId' is incomplete." }
    if ([string]::IsNullOrWhiteSpace([string]$recovery.boardId) -or [string]::IsNullOrWhiteSpace([string]$recovery.osType) -or $chunkSha -notmatch '^[0-9a-f]{64}$') { throw "Recovery contract in profile '$VersionId' is incomplete." }

    $driveRoot = [System.IO.Path]::GetPathRoot($script:RepoRoot)
    $recoveryCache = Join-Path $driveRoot 'DevintoshRecoveryCache'

    $script:Devintosh = [pscustomobject]@{
        Version = [pscustomobject]@{
            Id = $VersionId
            ProfilePath = $profilePath
            Profile = $profile
            MacOSFamily = [string]$profile.macOSFamily
            MacOSMajorVersion = [int]$profile.macOSMajorVersion
        }
        OpenCore = [pscustomobject]@{
            Repository = [string]$oc.repository
            Version = [string]$oc.version
            Tag = [string]$oc.tag
            ReleaseUrl = [string]$oc.releaseUrl
            ReleaseSha256 = $ocSha
            ToolPath = [string]$oc.toolPath
            PinnedCommit = [string]$oc.pinnedCommit
        }
        Recovery = [pscustomobject]@{
            BoardId = [string]$recovery.boardId
            Mlb = [string]$recovery.mlb
            OsType = [string]$recovery.osType
            ChunklistSha256 = $chunkSha
            CacheRoot = $recoveryCache
            CacheKey = "{0}-{1}-{2}" -f $VersionId,[string]$recovery.boardId,[string]$recovery.osType
            CachePath = Join-Path $recoveryCache ("{0}-{1}-{2}" -f $VersionId,[string]$recovery.boardId,[string]$recovery.osType)
            BuildRoot = Join-Path $script:BuildRoot 'recovery'
            DmgPath = Join-Path (Join-Path $script:BuildRoot 'recovery') 'BaseSystem.dmg'
            ChunklistPath = Join-Path (Join-Path $script:BuildRoot 'recovery') 'BaseSystem.chunklist'
            ManifestPath = Join-Path (Join-Path $script:BuildRoot 'recovery') 'recovery-manifest.json'
        }
        Paths = [pscustomobject]@{
            RepoRoot = $script:RepoRoot
            BuildRoot = $script:BuildRoot
            LogRoot = $script:LogRoot
            BackupRoot = $script:BackupRoot
            EfiRoot = Join-Path $script:BuildRoot 'efi\EFI'
            OpenCoreRoot = Join-Path $script:BuildRoot 'efi\EFI\OC'
            OpenCoreConfig = Join-Path $script:BuildRoot 'efi\EFI\OC\config.plist'
            OpenCoreManifest = Join-Path (Join-Path $script:RepoRoot 'tools\opencore') 'release-manifest.json'
            HardwareInventory = Join-Path (Join-Path $script:BuildRoot 'opencore') 'hardware-detected.json'
        }
    }

    $env:DEVINTOSH_MACOS_VERSION = $VersionId
    $env:DEVINTOSH_RECOVERY_CACHE = $recoveryCache
    return $script:Devintosh
}

if (-not (Get-Variable -Name Devintosh -Scope Script -ErrorAction SilentlyContinue)) {
    Initialize-DevintoshProjectContext
}
