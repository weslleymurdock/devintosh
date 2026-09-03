#requires -Version 5.1
<#
.SYNOPSIS
    Validates the generated OpenCore config.plist with the pinned ocvalidate tool.
.DESCRIPTION
    Downloads the pinned OpenCore release, verifies its SHA-256, extracts
    Utilities/ocvalidate, and validates the generated config.plist directly.
    The configuration generator is responsible for emitting canonical UTF-8 XML;
    validation must exercise the actual artifact that will be placed in the EFI.
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
$totalSteps = 7
$versionPath = Join-Path $script:RepoRoot 'config\versions\sequoia.json'
$configPath = Join-Path $script:BuildRoot 'efi\EFI\OC\config.plist'
$toolRoot = Join-Path $script:BuildRoot 'opencore-validator'
$archivePath = Join-Path $toolRoot 'OpenCore-RELEASE.zip'
$extractRoot = Join-Path $toolRoot 'extracted'
$validatorPath = Join-Path $toolRoot 'ocvalidate.exe'
$reportPath = Join-Path $script:BuildRoot 'opencore\validation-report.json'

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

try {
    $step++; Write-DevintoshProgress $step $totalSteps 'Checking OpenCore candidate and pinned release configuration'
    if (-not (Test-Path -LiteralPath $versionPath)) { $EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND; throw "Missing Sequoia configuration: $versionPath" }
    if (-not (Test-Path -LiteralPath $configPath)) { $EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND; throw "OpenCore config.plist not found: $configPath" }
    $config=Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8|ConvertFrom-Json
    $url=[string]$config.opencore.releaseUrl;$expectedSha=([string]$config.opencore.releaseSha256).ToLowerInvariant();$version=[string]$config.opencore.version
    if([string]::IsNullOrWhiteSpace($url)-or[string]::IsNullOrWhiteSpace($expectedSha)-or[string]::IsNullOrWhiteSpace($version)){$EXIT_CODE=$script:EXIT_VALIDATION_FAILURE;throw 'Pinned OpenCore release configuration is incomplete.'}
    Write-DevintoshStepLog $step "OpenCore $version validation target is ready." 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Preparing isolated ocvalidate workspace'
    if(-not(Test-Path -LiteralPath $toolRoot)){New-Item -ItemType Directory -Path $toolRoot -Force|Out-Null};if(Test-Path -LiteralPath $extractRoot){Remove-Item -LiteralPath $extractRoot -Recurse -Force};Write-DevintoshStepLog $step 'Validation workspace prepared.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Downloading pinned OpenCore release for validation'
    Invoke-WebRequest -Uri $url -UseBasicParsing -OutFile $archivePath
    if(-not(Test-Path -LiteralPath $archivePath)){$EXIT_CODE=$script:EXIT_DEPENDENCY_FAILURE;throw 'OpenCore validation archive was not downloaded.'}
    Write-DevintoshStepLog $step 'Pinned OpenCore release downloaded.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Verifying pinned OpenCore release integrity'
    $actualSha=Get-FileSha256 $archivePath
    if($actualSha -ne $expectedSha){$EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE;throw "OpenCore validation archive SHA-256 mismatch. Expected $expectedSha; received $actualSha."}
    Write-DevintoshStepLog $step "OpenCore release SHA-256 verified: $actualSha." 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Extracting pinned ocvalidate utility'
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot -Force
    $candidate=Join-Path $extractRoot 'Utilities\ocvalidate\ocvalidate.exe'
    if(-not(Test-Path -LiteralPath $candidate)){$EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE;throw "Pinned OpenCore archive is missing Utilities/ocvalidate/ocvalidate.exe: $candidate"}
    Copy-Item -LiteralPath $candidate -Destination $validatorPath -Force
    Write-DevintoshStepLog $step 'Pinned ocvalidate utility extracted.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Validating generated config.plist directly with ocvalidate'
    & $validatorPath $configPath
    $validatorExitCode=$LASTEXITCODE
    if($validatorExitCode -ne 0){$EXIT_CODE=$script:EXIT_VALIDATION_FAILURE;throw "ocvalidate rejected config.plist with exit code $validatorExitCode."}
    Write-DevintoshStepLog $step 'ocvalidate accepted the generated config.plist artifact directly.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Writing OpenCore validation report'
    $report=[ordered]@{schemaVersion=2;generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture);validator='OpenCorePkg Utilities/ocvalidate';openCoreVersion=$version;releaseSha256=$actualSha;configPath='build/efi/EFI/OC/config.plist';status='Valid';validatorExitCode=[int]$validatorExitCode;validationTarget='generated-artifact-direct'}
    $report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $reportPath -Encoding UTF8
    if(Test-Path -LiteralPath $extractRoot){Remove-Item -LiteralPath $extractRoot -Recurse -Force};if(Test-Path -LiteralPath $archivePath){Remove-Item -LiteralPath $archivePath -Force}
    Write-DevintoshStepLog $step 'OpenCore validation report written.' 'PASS';Complete-DevintoshProgress 'OpenCore config validation complete';exit $script:EXIT_SUCCESS
}
catch{
    Write-DevintoshStepLog $step "OpenCore validation failed: $($_.Exception.Message)" 'FAIL';Write-DevintoshLog 'ERROR' $_.Exception.ToString();exit $EXIT_CODE
}
