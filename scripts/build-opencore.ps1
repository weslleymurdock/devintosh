#requires -Version 5.1
<#
.SYNOPSIS
    Downloads, verifies and stages a pinned OpenCore release for Devintosh.

.DESCRIPTION
    Downloads the OpenCore RELEASE archive from the official Acidanthera GitHub
    release, verifies its published SHA-256 digest, extracts the X64 EFI payload,
    and stages it under build/efi/EFI. This phase intentionally does not generate
    or modify config.plist; hardware-specific configuration is handled later.

.PARAMETER Force
    Replaces an existing staged EFI after creating a backup.

.EXIT CODES
    0 = OpenCore staging completed successfully.
    1 = General build failure.
    2 = Validation failure.
    3 = Administrator privileges are required.
    4 = Required configuration or resource was not found.
    5 = Automatic rollback failed.
    6 = External dependency or network failure.
    7 = OpenCore archive integrity failure.
    8 = Unsupported configuration.
#>

[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\console.ps1"
. "$PSScriptRoot\lib\logging.ps1"
. "$PSScriptRoot\lib\progress.ps1"
. "$PSScriptRoot\lib\rollback.ps1"

$EXIT_CODE = $script:EXIT_SUCCESS
$step = 0
$totalSteps = 8
$configPath = Join-Path $script:RepoRoot 'config\versions\sequoia.json'
$efiRoot = Join-Path $script:BuildRoot 'efi'
$toolRoot = Join-Path $script:RepoRoot 'tools\opencore'
$tempRoot = Join-Path $script:BuildRoot ("opencore-download-" + [Guid]::NewGuid().ToString('N'))
$manifestPath = Join-Path $toolRoot 'release-manifest.json'

function Get-FileMetadata {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    return [ordered]@{
        name = $item.Name
        sizeBytes = [int64]$item.Length
        sha256 = $hash
    }
}

function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $partial = "$Destination.download"
    if (Test-Path -LiteralPath $partial) {
        Remove-Item -LiteralPath $partial -Force
    }
    Invoke-WebRequest -Uri $Uri -UseBasicParsing -OutFile $partial
    if (-not (Test-Path -LiteralPath $partial)) {
        throw "Download did not create $partial"
    }
    Move-Item -LiteralPath $partial -Destination $Destination -Force
}

try {
    $step++
    Write-DevintoshProgress $step $totalSteps 'Checking PowerShell and build prerequisites'
    if (-not (Test-IsAdministrator)) {
        Write-DevintoshStepLog $step 'Administrator privileges are required for the OpenCore build workflow.' 'FAIL'
        $EXIT_CODE = $script:EXIT_INSUFFICIENT_PRIVILEGES
        throw 'Run build-opencore.ps1 from an elevated PowerShell session.'
    }
    if (-not (Get-Command Expand-Archive -ErrorAction SilentlyContinue)) {
        Write-DevintoshStepLog $step 'Expand-Archive is unavailable in this PowerShell runtime.' 'FAIL'
        $EXIT_CODE = $script:EXIT_DEPENDENCY_FAILURE
        throw 'PowerShell Expand-Archive is required.'
    }
    Write-DevintoshStepLog $step 'PowerShell build prerequisites are available.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Loading pinned OpenCore release configuration'
    if (-not (Test-Path -LiteralPath $configPath)) {
        Write-DevintoshStepLog $step "Missing Sequoia configuration: $configPath" 'FAIL'
        $EXIT_CODE = $script:EXIT_TARGET_NOT_FOUND
        throw 'Sequoia configuration was not found.'
    }
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($config.macOSMajorVersion -ne 15) {
        Write-DevintoshStepLog $step 'OpenCore build is currently scoped to macOS Sequoia.' 'FAIL'
        $EXIT_CODE = $script:EXIT_UNSUPPORTED_CONFIGURATION
        throw 'Unsupported macOS target.'
    }
    $openCoreVersion = [string]$config.opencore.version
    $openCoreTag = [string]$config.opencore.tag
    $openCoreSha256 = ([string]$config.opencore.releaseSha256).ToLowerInvariant()
    $openCoreUrl = [string]$config.opencore.releaseUrl
    if ([string]::IsNullOrWhiteSpace($openCoreVersion) -or [string]::IsNullOrWhiteSpace($openCoreTag) -or [string]::IsNullOrWhiteSpace($openCoreSha256) -or [string]::IsNullOrWhiteSpace($openCoreUrl)) {
        $EXIT_CODE = $script:EXIT_VALIDATION_FAILURE
        throw 'OpenCore release configuration is incomplete.'
    }
    if ($openCoreSha256 -notmatch '^[0-9a-f]{64}$') {
        $EXIT_CODE = $script:EXIT_VALIDATION_FAILURE
        throw 'OpenCore release SHA-256 is invalid.'
    }
    Write-DevintoshStepLog $step "OpenCore $openCoreVersion release selected." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Preparing OpenCore release workspace'
    foreach ($directory in @($toolRoot, $tempRoot, $efiRoot)) {
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
    }
    Add-DevintoshRollbackAction "Remove temporary OpenCore directory $tempRoot" {
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
    Write-DevintoshStepLog $step 'OpenCore staging workspace prepared.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Downloading pinned OpenCore RELEASE archive'
    $archivePath = Join-Path $tempRoot ("OpenCore-$openCoreVersion-RELEASE.zip")
    Invoke-DownloadFile -Uri $openCoreUrl -Destination $archivePath
    Write-DevintoshLog 'INFO' "OpenCore archive downloaded from $openCoreUrl."
    Write-DevintoshStepLog $step 'OpenCore RELEASE archive downloaded.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Verifying OpenCore archive SHA-256'
    $archiveMeta = Get-FileMetadata $archivePath
    if ($archiveMeta.sha256 -ne $openCoreSha256) {
        Write-DevintoshStepLog $step "SHA-256 mismatch. Expected $openCoreSha256; received $($archiveMeta.sha256)." 'FAIL'
        $EXIT_CODE = $script:EXIT_ASSET_INTEGRITY_FAILURE
        throw 'OpenCore release archive integrity verification failed.'
    }
    Write-DevintoshStepLog $step "OpenCore archive SHA-256 verified: $($archiveMeta.sha256)." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Extracting OpenCore EFI payload'
    $extractRoot = Join-Path $tempRoot 'extracted'
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot -Force

    $x64EfiRoot = Join-Path $extractRoot 'X64\EFI'
    $sourceBoot = Join-Path $x64EfiRoot 'BOOT\BOOTx64.efi'
    $sourceOpenCore = Join-Path $x64EfiRoot 'OC\OpenCore.efi'
    $sourceOcRoot = Join-Path $x64EfiRoot 'OC'

    if (-not (Test-Path -LiteralPath $x64EfiRoot -PathType Container)) {
        $EXIT_CODE = $script:EXIT_ASSET_INTEGRITY_FAILURE
        throw "OpenCore archive is missing expected X64\EFI directory: $x64EfiRoot"
    }
    if (-not (Test-Path -LiteralPath $sourceBoot -PathType Leaf)) {
        $EXIT_CODE = $script:EXIT_ASSET_INTEGRITY_FAILURE
        throw "OpenCore archive is missing BOOTx64.efi: $sourceBoot"
    }
    if (-not (Test-Path -LiteralPath $sourceOpenCore -PathType Leaf)) {
        $EXIT_CODE = $script:EXIT_ASSET_INTEGRITY_FAILURE
        throw "OpenCore archive is missing OpenCore.efi: $sourceOpenCore"
    }
    if (-not (Test-Path -LiteralPath $sourceOcRoot -PathType Container)) {
        $EXIT_CODE = $script:EXIT_ASSET_INTEGRITY_FAILURE
        throw "OpenCore archive is missing X64\EFI\OC directory: $sourceOcRoot"
    }

    Write-DevintoshLog 'INFO' "OpenCore X64 EFI root: $x64EfiRoot"
    Write-DevintoshLog 'INFO' "OpenCore bootstrap: $sourceBoot"
    Write-DevintoshLog 'INFO' "OpenCore binary: $sourceOpenCore"
    Write-DevintoshStepLog $step 'OpenCore EFI payload extracted and expected layout validated.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Staging OpenCore EFI payload'
    if (Test-Path -LiteralPath $efiRoot) {
        $existingEntries = @(Get-ChildItem -LiteralPath $efiRoot -Force -ErrorAction SilentlyContinue)
        if ($existingEntries.Count -gt 0) {
            if (-not $Force) {
                Write-DevintoshStepLog $step 'A staged EFI already exists. Use -Force to replace it safely.' 'FAIL'
                $EXIT_CODE = $script:EXIT_VALIDATION_FAILURE
                throw 'Existing staged EFI found.'
            }
            $backupRoot = Join-Path $script:BackupRoot ("opencore-" + (Get-Timestamp -replace '[^0-9]',''))
            New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $efiRoot '*') -Destination $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
            Add-DevintoshRollbackAction "Restore previous EFI from $backupRoot" {
                if (Test-Path -LiteralPath $backupRoot) {
                    if (Test-Path -LiteralPath $efiRoot) { Remove-Item -LiteralPath $efiRoot -Recurse -Force }
                    New-Item -ItemType Directory -Path $efiRoot -Force | Out-Null
                    Copy-Item -LiteralPath (Join-Path $backupRoot '*') -Destination $efiRoot -Recurse -Force
                }
            }
        }
    }
    if (Test-Path -LiteralPath $efiRoot) {
        Get-ChildItem -LiteralPath $efiRoot -Force | Remove-Item -Recurse -Force
    }
    New-Item -ItemType Directory -Path $efiRoot -Force | Out-Null
    Copy-Item -LiteralPath $sourceBoot -Destination (Join-Path $efiRoot 'BOOTx64.efi') -Force
    Copy-Item -LiteralPath $sourceOcRoot -Destination (Join-Path $efiRoot 'OC') -Recurse -Force
    $stagedOpenCore = Join-Path $efiRoot 'OC\OpenCore.efi'
    $stagedBoot = Join-Path $efiRoot 'BOOTx64.efi'
    if (-not (Test-Path -LiteralPath $stagedOpenCore) -or -not (Test-Path -LiteralPath $stagedBoot)) {
        $EXIT_CODE = $script:EXIT_ASSET_INTEGRITY_FAILURE
        throw 'Staged OpenCore EFI payload is incomplete.'
    }
    Write-DevintoshStepLog $step 'OpenCore EFI payload staged under build/efi/EFI.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Writing OpenCore release manifest'
    $manifest = [ordered]@{
        schemaVersion = 1
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        culture = 'en-US'
        macOSFamily = 'Sequoia'
        macOSMajorVersion = 15
        repository = 'acidanthera/OpenCorePkg'
        version = $openCoreVersion
        tag = $openCoreTag
        releaseUrl = $openCoreUrl
        archive = $archiveMeta
        verification = 'SHA-256 matched the pinned release digest'
        configPlistStatus = 'not generated; hardware-specific configuration is a later phase'
    }
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Write-DevintoshStepLog $step "Release manifest written to $manifestPath." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Finalizing OpenCore build transaction'
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
    Complete-DevintoshTransaction
    Write-DevintoshStepLog $step 'OpenCore RELEASE is ready for hardware-specific configuration.' 'PASS'
    Complete-DevintoshProgress 'OpenCore staging complete'
    exit $script:EXIT_SUCCESS
}
catch {
    Write-DevintoshLog 'ERROR' $_.Exception.ToString()
    if ($EXIT_CODE -eq $script:EXIT_SUCCESS) { $EXIT_CODE = $script:EXIT_GENERAL_FAILURE }
    Write-DevintoshStepLog $step 'OpenCore build failed; starting automatic rollback.' 'FAIL'
    $rollbackOk = Invoke-DevintoshRollback
    if (-not $rollbackOk) { $EXIT_CODE = $script:EXIT_ROLLBACK_FAILURE }
    Write-DevintoshProgress $step $totalSteps 'OpenCore build failed'
    Write-Host ''
    Write-Host "[$($script:Red)FAIL$($script:Reset)] build-opencore.ps1 exited with code $EXIT_CODE"
    exit $EXIT_CODE
}
