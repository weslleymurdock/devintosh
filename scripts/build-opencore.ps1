#requires -Version 5.1
<#
.SYNOPSIS
    Downloads, verifies and stages a pinned OpenCore release for Devintosh.
.DESCRIPTION
    Downloads the OpenCore RELEASE archive from the official Acidanthera GitHub
    release, verifies its pinned SHA-256 digest, extracts the X64 EFI payload,
    and stages it under build/efi/EFI. This phase intentionally does not generate
    or modify config.plist; hardware-specific configuration is handled later.

    The archive layout is validated using the canonical X64/EFI paths first and
    falls back to unique recursive discovery for forward compatibility with release
    packaging changes. EFI staging is performed from a temporary directory so a
    failed copy cannot leave a partially populated build/efi tree.
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
param([switch]$Force)
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
    return [ordered]@{ name=$item.Name; sizeBytes=[int64]$item.Length; sha256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
}
function Invoke-DownloadFile {
    param([Parameter(Mandatory = $true)][string]$Uri,[Parameter(Mandatory = $true)][string]$Destination)
    $parent=Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $partial="$Destination.download"
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    Invoke-WebRequest -Uri $Uri -UseBasicParsing -OutFile $partial
    if (-not (Test-Path -LiteralPath $partial -PathType Leaf)) { throw "Download did not create $partial" }
    Move-Item -LiteralPath $partial -Destination $Destination -Force
}
function Resolve-OpenCorePayload {
    param([Parameter(Mandatory = $true)][string]$ExtractRoot)
    $canonicalRoot=Join-Path $ExtractRoot 'X64\EFI'
    $canonicalBoot=Join-Path $canonicalRoot 'BOOT\BOOTx64.efi'
    $canonicalOc=Join-Path $canonicalRoot 'OC'
    $canonicalOpenCore=Join-Path $canonicalOc 'OpenCore.efi'
    if ((Test-Path -LiteralPath $canonicalBoot -PathType Leaf) -and (Test-Path -LiteralPath $canonicalOc -PathType Container) -and (Test-Path -LiteralPath $canonicalOpenCore -PathType Leaf)) {
        return [pscustomobject]@{ EfiRoot=$canonicalRoot; Boot=$canonicalBoot; Oc=$canonicalOc; OpenCore=$canonicalOpenCore; Discovery='canonical' }
    }
    $bootMatches=@(Get-ChildItem -LiteralPath $ExtractRoot -Filter 'BOOTx64.efi' -File -Recurse -ErrorAction SilentlyContinue)
    $openCoreMatches=@(Get-ChildItem -LiteralPath $ExtractRoot -Filter 'OpenCore.efi' -File -Recurse -ErrorAction SilentlyContinue)
    if ($bootMatches.Count -ne 1 -or $openCoreMatches.Count -ne 1) { throw "OpenCore archive EFI payload could not be resolved safely. BOOTx64.efi matches=$($bootMatches.Count); OpenCore.efi matches=$($openCoreMatches.Count)." }
    $boot=$bootMatches[0].FullName; $openCore=$openCoreMatches[0].FullName; $oc=Split-Path -Parent $openCore; $efi=Split-Path -Parent $oc
    if (-not (Test-Path -LiteralPath $oc -PathType Container) -or -not (Test-Path -LiteralPath $efi -PathType Container)) { throw 'OpenCore archive EFI directory layout is incomplete.' }
    return [pscustomobject]@{ EfiRoot=$efi; Boot=$boot; Oc=$oc; OpenCore=$openCore; Discovery='recursive-unique' }
}
function Copy-DirectoryContents {
    param([Parameter(Mandatory = $true)][string]$Source,[Parameter(Mandatory = $true)][string]$Destination)
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
    foreach ($entry in @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop)) { Copy-Item -LiteralPath $entry.FullName -Destination $Destination -Recurse -Force -ErrorAction Stop }
}
try {
    $step++; Write-DevintoshProgress $step $totalSteps 'Checking PowerShell and build prerequisites'
    if (-not (Test-IsAdministrator)) { $EXIT_CODE=$script:EXIT_INSUFFICIENT_PRIVILEGES; throw 'Run build-opencore.ps1 from an elevated PowerShell session.' }
    if (-not (Get-Command Expand-Archive -ErrorAction SilentlyContinue)) { $EXIT_CODE=$script:EXIT_DEPENDENCY_FAILURE; throw 'PowerShell Expand-Archive is required.' }
    Write-DevintoshStepLog $step 'PowerShell build prerequisites are available.' 'PASS'
    $step++; Write-DevintoshProgress $step $totalSteps 'Loading pinned OpenCore release configuration'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { $EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND; throw "Missing Sequoia configuration: $configPath" }
    $config=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$config.macOSMajorVersion -ne 15) { $EXIT_CODE=$script:EXIT_UNSUPPORTED_CONFIGURATION; throw 'OpenCore build is currently scoped to macOS Sequoia.' }
    $openCoreVersion=[string]$config.opencore.version; $openCoreTag=[string]$config.opencore.tag; $openCoreSha256=([string]$config.opencore.releaseSha256).ToLowerInvariant(); $openCoreUrl=[string]$config.opencore.releaseUrl
    if ([string]::IsNullOrWhiteSpace($openCoreVersion) -or [string]::IsNullOrWhiteSpace($openCoreTag) -or [string]::IsNullOrWhiteSpace($openCoreSha256) -or [string]::IsNullOrWhiteSpace($openCoreUrl)) { $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw 'OpenCore release configuration is incomplete.' }
    if ($openCoreSha256 -notmatch '^[0-9a-f]{64}$') { $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw 'OpenCore release SHA-256 is invalid.' }
    Write-DevintoshStepLog $step "OpenCore $openCoreVersion release selected." 'PASS'
    $step++; Write-DevintoshProgress $step $totalSteps 'Preparing OpenCore release workspace'
    foreach ($directory in @($toolRoot,$tempRoot)) { if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null } }
    Add-DevintoshRollbackAction "Remove temporary OpenCore directory $tempRoot" { if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force } }
    Write-DevintoshStepLog $step 'OpenCore staging workspace prepared.' 'PASS'
    $step++; Write-DevintoshProgress $step $totalSteps 'Downloading pinned OpenCore RELEASE archive'
    $archivePath=Join-Path $tempRoot ("OpenCore-$openCoreVersion-RELEASE.zip"); Invoke-DownloadFile -Uri $openCoreUrl -Destination $archivePath
    Write-DevintoshLog 'INFO' "OpenCore archive downloaded from $openCoreUrl."; Write-DevintoshStepLog $step 'OpenCore RELEASE archive downloaded.' 'PASS'
    $step++; Write-DevintoshProgress $step $totalSteps 'Verifying OpenCore archive SHA-256'
    $archiveMeta=Get-FileMetadata $archivePath
    if ($archiveMeta.sha256 -ne $openCoreSha256) { $EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE; throw "OpenCore release archive integrity verification failed. Expected $openCoreSha256; received $($archiveMeta.sha256)." }
    Write-DevintoshStepLog $step "OpenCore archive SHA-256 verified: $($archiveMeta.sha256)." 'PASS'
    $step++; Write-DevintoshProgress $step $totalSteps 'Extracting OpenCore EFI payload'
    $extractRoot=Join-Path $tempRoot 'extracted'; Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot -Force
    $payload=Resolve-OpenCorePayload -ExtractRoot $extractRoot
    Write-DevintoshLog 'INFO' "OpenCore EFI discovery mode: $($payload.Discovery)."; Write-DevintoshLog 'INFO' "OpenCore bootstrap source: $($payload.Boot)"; Write-DevintoshLog 'INFO' "OpenCore binary source: $($payload.OpenCore)"
    Write-DevintoshStepLog $step 'OpenCore EFI payload extracted and layout validated.' 'PASS'
    $step++; Write-DevintoshProgress $step $totalSteps 'Staging OpenCore EFI payload'
    $stageRoot=Join-Path $tempRoot 'stage\EFI'; $stageBoot=Join-Path $stageRoot 'BOOT'; $stageOc=Join-Path $stageRoot 'OC'; New-Item -ItemType Directory -Path $stageBoot,$stageOc -Force | Out-Null
    Copy-Item -LiteralPath $payload.Boot -Destination (Join-Path $stageBoot 'BOOTx64.efi') -Force -ErrorAction Stop
    Copy-DirectoryContents -Source $payload.Oc -Destination $stageOc
    $stagedOpenCore=Join-Path $stageOc 'OpenCore.efi'; $stagedBoot=Join-Path $stageBoot 'BOOTx64.efi'
    if (-not (Test-Path -LiteralPath $stagedOpenCore -PathType Leaf) -or -not (Test-Path -LiteralPath $stagedBoot -PathType Leaf)) { $EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE; throw 'Temporary OpenCore EFI staging payload is incomplete.' }
    if (-not (Test-Path -LiteralPath $efiRoot -PathType Container)) { New-Item -ItemType Directory -Path $efiRoot -Force | Out-Null }
    $backupRoot=$null; $existingEntries=@(Get-ChildItem -LiteralPath $efiRoot -Force -ErrorAction SilentlyContinue)
    if ($existingEntries.Count -gt 0) {
        if (-not $Force) { $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw 'Existing staged EFI found. Use -Force to replace it safely.' }
        $backupRoot=Join-Path $script:BackupRoot ("opencore-" + (Get-Timestamp -replace '[^0-9]','')); New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        foreach ($entry in $existingEntries) { Copy-Item -LiteralPath $entry.FullName -Destination $backupRoot -Recurse -Force -ErrorAction Stop }
        Add-DevintoshRollbackAction "Restore previous EFI from $backupRoot" {
            if (Test-Path -LiteralPath $efiRoot) { Remove-Item -LiteralPath $efiRoot -Recurse -Force }
            New-Item -ItemType Directory -Path $efiRoot -Force | Out-Null
            if (Test-Path -LiteralPath $backupRoot) { Copy-DirectoryContents -Source $backupRoot -Destination $efiRoot }
        }
    }
    $targetOc=Join-Path $efiRoot 'OC'; $targetBoot=Join-Path $efiRoot 'BOOT'
    if (Test-Path -LiteralPath $targetOc) { Remove-Item -LiteralPath $targetOc -Recurse -Force }; if (Test-Path -LiteralPath $targetBoot) { Remove-Item -LiteralPath $targetBoot -Recurse -Force }
    New-Item -ItemType Directory -Path $targetOc,$targetBoot -Force | Out-Null
    Copy-DirectoryContents -Source $stageOc -Destination $targetOc
    Copy-Item -LiteralPath $stagedBoot -Destination (Join-Path $targetBoot 'BOOTx64.efi') -Force -ErrorAction Stop
    $finalOpenCore=Join-Path $targetOc 'OpenCore.efi'; $finalBoot=Join-Path $targetBoot 'BOOTx64.efi'
    if (-not (Test-Path -LiteralPath $finalOpenCore -PathType Leaf) -or -not (Test-Path -LiteralPath $finalBoot -PathType Leaf)) { $EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE; throw 'Final OpenCore EFI payload is incomplete after staging.' }
    Write-DevintoshStepLog $step 'OpenCore EFI payload staged under build/efi/EFI/.' 'PASS'
    $step++; Write-DevintoshProgress $step $totalSteps 'Writing OpenCore release manifest'
    $manifest=[ordered]@{schemaVersion=2;generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture);culture='en-US';macOSFamily='Sequoia';macOSMajorVersion=15;repository='acidanthera/OpenCorePkg';version=$openCoreVersion;tag=$openCoreTag;releaseUrl=$openCoreUrl;archive=$archiveMeta;verification='SHA-256 matched the pinned release digest';payloadDiscovery=$payload.Discovery;efiRoot='build/efi/EFI';configPlistStatus='not generated; hardware-specific configuration is a later phase'}
    $manifest|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $manifestPath -Encoding UTF8; Write-DevintoshStepLog $step "Release manifest written to $manifestPath." 'PASS'
    $step++; Write-DevintoshProgress $step $totalSteps 'Finalizing OpenCore build transaction'
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    Complete-DevintoshTransaction; Write-DevintoshStepLog $step 'OpenCore RELEASE is ready for hardware-specific configuration.' 'PASS'; Complete-DevintoshProgress 'OpenCore staging complete'; exit $script:EXIT_SUCCESS
}
catch {
    Write-DevintoshLog 'ERROR' $_.Exception.ToString()
    if ($EXIT_CODE -eq $script:EXIT_SUCCESS) { $EXIT_CODE=$script:EXIT_GENERAL_FAILURE }
    Write-DevintoshStepLog $step "OpenCore build failed: $($_.Exception.Message). Starting automatic rollback." 'FAIL'
    $rollbackOk=Invoke-DevintoshRollback; if (-not $rollbackOk) { $EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE }
    Write-DevintoshProgress $step $totalSteps 'OpenCore build failed'; Write-Host ''; Write-Host "[$($script:Red)FAIL$($script:Reset)] build-opencore.ps1 exited with code $EXIT_CODE"; exit $EXIT_CODE
}
