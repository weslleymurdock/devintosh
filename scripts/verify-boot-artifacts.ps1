#requires -Version 5.1
<#
.SYNOPSIS
    Verifies all artifacts required by the destructive boot-disk stage.
.DESCRIPTION
    This gate runs immediately before prepare-boot-disk.ps1. It verifies the canonical
    build/efi/EFI layout, generated OpenCore config/loader, Apple Recovery payload, and
    the version/profile identity. It intentionally performs no storage mutation and no
    destructive operation.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\console.ps1"
. "$PSScriptRoot\lib\logging.ps1"
. "$PSScriptRoot\lib\progress.ps1"
. "$PSScriptRoot\lib\version-profile.ps1"

$EXIT_CODE = $script:EXIT_SUCCESS
$step = 0
$totalSteps = 4

try {
    $step++
    Write-DevintoshProgress $step $totalSteps 'Loading the selected macOS/OpenCore target'
    $profile = Get-DevintoshVersionProfile
    Write-DevintoshStepLog $step "$($profile.macOSFamily) target uses OpenCore $($profile.opencore.version)." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Checking canonical OpenCore EFI artifacts'
    $efiRoot = Join-Path $script:BuildRoot 'efi\EFI'
    $required = @(
        (Join-Path $efiRoot 'BOOT\BOOTx64.efi'),
        (Join-Path $efiRoot 'OC\OpenCore.efi'),
        (Join-Path $efiRoot 'OC\config.plist')
    )
    foreach ($path in $required) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $EXIT_CODE = $script:EXIT_TARGET_NOT_FOUND
            throw "Required generated boot artifact is missing: $path"
        }
    }
    Write-DevintoshStepLog $step 'Canonical EFI/BOOT and EFI/OC artifacts are present.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Checking verified Apple Recovery artifacts'
    $recoveryRoot = Join-Path $script:BuildRoot 'recovery'
    $recoveryManifestPath = Join-Path $recoveryRoot 'recovery-manifest.json'
    $dmg = Join-Path $recoveryRoot 'BaseSystem.dmg'
    $chunk = Join-Path $recoveryRoot 'BaseSystem.chunklist'
    foreach ($path in @($dmg,$chunk,$recoveryManifestPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $EXIT_CODE = $script:EXIT_TARGET_NOT_FOUND
            throw "Required verified Recovery artifact is missing: $path"
        }
    }
    $manifest = Get-Content -LiteralPath $recoveryManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$manifest.targetId -ne [string]$profile.id -or [string]$manifest.boardId -ne [string]$profile.recovery.boardId -or [string]$manifest.osType -ne [string]$profile.recovery.osType -or ([string]$manifest.pinnedChunklistSha256).ToLowerInvariant() -ne ([string]$profile.recovery.chunklistSha256).ToLowerInvariant()) {
        $EXIT_CODE = $script:EXIT_VALIDATION_FAILURE
        throw 'Recovery manifest does not match the selected macOS version profile.'
    }
    $actualChunkSha = (Get-FileHash -LiteralPath $chunk -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedChunkSha = ([string]$profile.recovery.chunklistSha256).ToLowerInvariant()
    if ($actualChunkSha -ne $expectedChunkSha) {
        $EXIT_CODE = $script:EXIT_ASSET_INTEGRITY_FAILURE
        throw "Recovery chunklist SHA-256 mismatch. Expected $expectedChunkSha; received $actualChunkSha."
    }
    Write-DevintoshStepLog $step 'Apple Recovery payload and pinned chunklist integrity are present.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Finalizing non-destructive boot artifact gate'
    Write-DevintoshStepLog $step 'All artifacts required by prepare-boot-disk.ps1 are ready; no disk changes were made.' 'PASS'
    Complete-DevintoshProgress 'Boot artifact gate complete'
    exit $script:EXIT_SUCCESS
}
catch {
    Write-DevintoshLog 'ERROR' "Boot artifact gate failed: $($_.Exception.Message)"
    if ($EXIT_CODE -eq $script:EXIT_SUCCESS) { $EXIT_CODE = $script:EXIT_GENERAL_FAILURE }
    Write-DevintoshProgress $step $totalSteps 'Boot artifact gate failed'
    exit $EXIT_CODE
}
