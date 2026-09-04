#requires -Version 5.1
<#
.SYNOPSIS
    Downloads, verifies and stages a pinned OpenCore release for Devintosh.
.DESCRIPTION
    Downloads the OpenCore RELEASE archive from the target macOS version profile,
    verifies its pinned SHA-256 digest, extracts the X64 EFI payload, and stages it
    under build/efi/EFI. This phase intentionally does not generate or modify
    config.plist; hardware-specific configuration is handled later.
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
. "$PSScriptRoot\lib\version-profile.ps1"

$EXIT_CODE = $script:EXIT_SUCCESS
$step = 0
$totalSteps = 8
$efiRoot = Join-Path $script:BuildRoot 'efi\EFI'
$toolRoot = Join-Path $script:RepoRoot 'tools\opencore'
$tempRoot = Join-Path $script:BuildRoot ("opencore-download-" + [Guid]::NewGuid().ToString('N'))
$manifestPath = Join-Path $toolRoot 'release-manifest.json'
$versionProfile = Get-DevintoshVersionProfile
$openCoreProfile = Get-DevintoshOpenCoreProfile
$openCoreVersion = [string]$openCoreProfile.version
$openCoreTag = [string]$openCoreProfile.tag
$openCoreSha256 = ([string]$openCoreProfile.releaseSha256).ToLowerInvariant()
$openCoreUrl = [string]$openCoreProfile.releaseUrl

function Get-FileMetadata {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    return [ordered]@{ name=$item.Name; sizeBytes=[int64]$item.Length; sha256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
}

function Invoke-DownloadFile {
    param([Parameter(Mandatory = $true)][string]$Uri,[Parameter(Mandatory = $true)][string]$Destination)
    $parent=Split-Path -Parent $Destination
    if(-not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
    $partial="$Destination.download"
    if(Test-Path -LiteralPath $partial){Remove-Item -LiteralPath $partial -Force}
    Invoke-WebRequest -Uri $Uri -UseBasicParsing -OutFile $partial
    if(-not(Test-Path -LiteralPath $partial)){throw "Download did not create $partial"}
    Move-Item -LiteralPath $partial -Destination $Destination -Force
}

try {
    $step++;Write-DevintoshProgress $step $totalSteps 'Checking PowerShell and build prerequisites'
    if(-not(Test-IsAdministrator)){$EXIT_CODE=$script:EXIT_INSUFFICIENT_PRIVILEGES;throw 'Run build-opencore.ps1 from an elevated PowerShell session.'}
    if(-not(Get-Command Expand-Archive -ErrorAction SilentlyContinue)){$EXIT_CODE=$script:EXIT_DEPENDENCY_FAILURE;throw 'PowerShell Expand-Archive is required.'}
    Write-DevintoshStepLog $step 'PowerShell build prerequisites are available.' 'PASS'

    $step++;Write-DevintoshProgress $step $totalSteps 'Loading pinned OpenCore release configuration'
    if([string]::IsNullOrWhiteSpace($openCoreVersion)-or[string]::IsNullOrWhiteSpace($openCoreTag)-or[string]::IsNullOrWhiteSpace($openCoreUrl)-or$openCoreSha256-notmatch'^[0-9a-f]{64}$'){$EXIT_CODE=$script:EXIT_VALIDATION_FAILURE;throw 'OpenCore release configuration is incomplete or invalid.'}
    Write-DevintoshStepLog $step "$($versionProfile.macOSFamily) target selected with OpenCore $openCoreVersion." 'PASS'

    $step++;Write-DevintoshProgress $step $totalSteps 'Preparing OpenCore release workspace'
    foreach($directory in @($toolRoot,$tempRoot,$efiRoot)){if(-not(Test-Path -LiteralPath $directory)){New-Item -ItemType Directory -Path $directory -Force|Out-Null}}
    Add-DevintoshRollbackAction "Remove temporary OpenCore directory $tempRoot" {if(Test-Path -LiteralPath $tempRoot){Remove-Item -LiteralPath $tempRoot -Recurse -Force}}
    Write-DevintoshStepLog $step 'OpenCore staging workspace prepared.' 'PASS'

    $step++;Write-DevintoshProgress $step $totalSteps 'Downloading pinned OpenCore RELEASE archive'
    $archivePath=Join-Path $tempRoot ("OpenCore-$openCoreVersion-RELEASE.zip")
    Invoke-DownloadFile -Uri $openCoreUrl -Destination $archivePath
    Write-DevintoshStepLog $step 'OpenCore RELEASE archive downloaded.' 'PASS'

    $step++;Write-DevintoshProgress $step $totalSteps 'Verifying OpenCore archive SHA-256'
    $archiveMeta=Get-FileMetadata $archivePath
    if($archiveMeta.sha256-ne$openCoreSha256){$EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE;throw "OpenCore release archive integrity verification failed. Expected $openCoreSha256; received $($archiveMeta.sha256)."}
    Write-DevintoshStepLog $step "OpenCore archive SHA-256 verified: $($archiveMeta.sha256)." 'PASS'

    $step++;Write-DevintoshProgress $step $totalSteps 'Extracting OpenCore EFI payload'
    $extractRoot=Join-Path $tempRoot 'extracted';Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot -Force
    $sourceEfiRoot=Join-Path $extractRoot 'X64\EFI';$sourceBoot=Join-Path $sourceEfiRoot 'BOOT\BOOTx64.efi';$sourceOcRoot=Join-Path $sourceEfiRoot 'OC';$sourceOpenCore=Join-Path $sourceOcRoot 'OpenCore.efi'
    if(-not(Test-Path -LiteralPath $sourceEfiRoot -PathType Container)){$EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE;throw "OpenCore archive is missing the expected EFI root: $sourceEfiRoot"}
    if(-not(Test-Path -LiteralPath $sourceBoot -PathType Leaf)){$EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE;throw "OpenCore archive is missing BOOTx64.efi: $sourceBoot"}
    if(-not(Test-Path -LiteralPath $sourceOcRoot -PathType Container)){$EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE;throw "OpenCore archive is missing the OC directory: $sourceOcRoot"}
    if(-not(Test-Path -LiteralPath $sourceOpenCore -PathType Leaf)){$EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE;throw "OpenCore archive is missing OpenCore.efi: $sourceOpenCore"}
    Write-DevintoshStepLog $step 'OpenCore EFI payload extracted and layout validated.' 'PASS'

    $step++;Write-DevintoshProgress $step $totalSteps 'Staging OpenCore EFI payload'
    if(Test-Path -LiteralPath $efiRoot){$existingEntries=@(Get-ChildItem -LiteralPath $efiRoot -Force -ErrorAction SilentlyContinue);if($existingEntries.Count-gt 0){if(-not$Force){$EXIT_CODE=$script:EXIT_VALIDATION_FAILURE;throw 'Existing staged EFI found. Use -Force to replace it safely.'};$backupRoot=Join-Path $script:BackupRoot ("opencore-"+(Get-Timestamp -replace '[^0-9]',''));New-Item -ItemType Directory -Path $backupRoot -Force|Out-Null;Copy-Item -LiteralPath (Join-Path $efiRoot '*') -Destination $backupRoot -Recurse -Force -ErrorAction SilentlyContinue;Add-DevintoshRollbackAction "Restore previous EFI from $backupRoot" {if(Test-Path -LiteralPath $backupRoot){if(Test-Path -LiteralPath $efiRoot){Remove-Item -LiteralPath $efiRoot -Recurse -Force};New-Item -ItemType Directory -Path $efiRoot -Force|Out-Null;Copy-Item -LiteralPath (Join-Path $backupRoot '*') -Destination $efiRoot -Recurse -Force}}}}
    if(Test-Path -LiteralPath $efiRoot){Get-ChildItem -LiteralPath $efiRoot -Force|Remove-Item -Recurse -Force}
    New-Item -ItemType Directory -Path $efiRoot -Force|Out-Null
    $bootRoot=Join-Path $efiRoot 'BOOT';New-Item -ItemType Directory -Path $bootRoot -Force|Out-Null
    Copy-Item -LiteralPath $sourceBoot -Destination (Join-Path $bootRoot 'BOOTx64.efi') -Force
    Copy-Item -LiteralPath $sourceOcRoot -Destination (Join-Path $efiRoot 'OC') -Recurse -Force
    if(-not(Test-Path -LiteralPath (Join-Path $efiRoot 'OC\OpenCore.efi'))-or-not(Test-Path -LiteralPath (Join-Path $bootRoot 'BOOTx64.efi'))){$EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE;throw 'Staged OpenCore EFI payload is incomplete.'}
    Write-DevintoshStepLog $step 'OpenCore EFI payload staged under build/efi/EFI.' 'PASS'

    $step++;Write-DevintoshProgress $step $totalSteps 'Writing OpenCore release manifest'
    $manifest=[ordered]@{schemaVersion=2;generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture);culture='en-US';targetId=[string]$versionProfile.id;macOSFamily=[string]$versionProfile.macOSFamily;macOSMajorVersion=[int]$versionProfile.macOSMajorVersion;repository=[string]$openCoreProfile.repository;version=$openCoreVersion;tag=$openCoreTag;releaseUrl=$openCoreUrl;archive=$archiveMeta;verification='SHA-256 matched the version-profile release digest';configPlistStatus='not generated; hardware-specific configuration is a later phase'}
    $manifest|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Write-DevintoshStepLog $step "Release manifest written to $manifestPath." 'PASS'

    $step++;Write-DevintoshProgress $step $totalSteps 'Finalizing OpenCore build transaction';if(Test-Path -LiteralPath $tempRoot){Remove-Item -LiteralPath $tempRoot -Recurse -Force};Complete-DevintoshTransaction;Write-DevintoshStepLog $step 'OpenCore RELEASE is ready for hardware-specific configuration.' 'PASS';Complete-DevintoshProgress 'OpenCore staging complete';exit $script:EXIT_SUCCESS
}
catch{Write-DevintoshLog 'ERROR' $_.Exception.ToString();if($EXIT_CODE-eq$script:EXIT_SUCCESS){$EXIT_CODE=$script:EXIT_GENERAL_FAILURE};Write-DevintoshStepLog $step 'OpenCore build failed; starting automatic rollback.' 'FAIL';$rollbackOk=Invoke-DevintoshRollback;if(-not$rollbackOk){$EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE};Write-DevintoshProgress $step $totalSteps 'OpenCore build failed';Write-Host "[$($script:Red)FAIL$($script:Reset)] build-opencore.ps1 exited with code $EXIT_CODE";exit $EXIT_CODE}
