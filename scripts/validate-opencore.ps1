#requires -Version 5.1
<#
.SYNOPSIS
    Validates the generated OpenCore config.plist with the pinned ocvalidate tool.
.DESCRIPTION
    Loads the selected macOS target profile, downloads its pinned OpenCore release,
    verifies the release SHA-256, extracts the matching ocvalidate utility, and
    validates the generated config.plist directly. The OS profile is the single
    source of truth for the OpenCore version used by this stage.
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
$configPath = Join-Path $script:BuildRoot 'efi\EFI\OC\config.plist'
$hfsPlusPath = Join-Path $script:BuildRoot 'efi\EFI\OC\Drivers\HfsPlus.efi'
$toolRoot = Join-Path $script:BuildRoot 'opencore-validator'
$archivePath = Join-Path $toolRoot 'OpenCore-RELEASE.zip'
$extractRoot = Join-Path $toolRoot 'extracted'
$validatorPath = Join-Path $toolRoot 'ocvalidate.exe'
$reportPath = Join-Path $script:BuildRoot 'opencore\validation-report.json'

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Get-PlistValue {
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Dictionary,[Parameter(Mandatory)][string]$Name)
    $keys=@($Dictionary.ChildNodes|Where-Object{$_.NodeType -eq 'Element' -and $_.Name -eq 'key' -and $_.InnerText -eq $Name})
    if($keys.Count -gt 1){throw "Duplicate plist key: $Name"};if($keys.Count -eq 0){return $null}
    $value=$keys[0].NextSibling;while($null -ne $value -and $value.NodeType -ne 'Element'){$value=$value.NextSibling};return $value
}
function Get-PlistDictionary {
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Root,[Parameter(Mandatory)][string[]]$Path)
    $current=$Root;foreach($name in $Path){$value=Get-PlistValue $current $name;if($null -eq $value -or $value.Name -ne 'dict'){return $null};$current=[System.Xml.XmlElement]$value};return $current
}
function Get-PlistArrayDictionaryByPath {
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Array,[Parameter(Mandatory)][string]$Path)
    foreach($entry in @($Array.ChildNodes|Where-Object{$_.NodeType-eq 'Element'})){
        if($entry.Name-ne 'dict'){continue}
        $pathValue=Get-PlistValue ([System.Xml.XmlElement]$entry) 'Path'
        if($null-ne $pathValue -and $pathValue.Name-eq 'string' -and $pathValue.InnerText-eq $Path){return [System.Xml.XmlElement]$entry}
    }
    return $null
}
function Test-FirstBootPrerequisites {
    param([Parameter(Mandatory)][System.Xml.XmlDocument]$Document)
    $root=[System.Xml.XmlElement]$Document.SelectSingleNode('/plist/dict');if($null-eq $root){throw 'Generated config.plist does not contain a valid plist/dict root.'}
    $generic=Get-PlistDictionary $root @('PlatformInfo','Generic');if($null-eq $generic){throw 'PlatformInfo/Generic dictionary is missing.'}
    $requiredStrings=@('SystemProductName','SystemSerialNumber','MLB','SystemUUID');foreach($name in $requiredStrings){$value=Get-PlistValue $generic $name;if($null-eq $value -or $value.Name-ne 'string' -or [string]::IsNullOrWhiteSpace($value.InnerText)){throw "PlatformInfo/Generic/$name is missing or empty."}}
    $uuidValue=[string](Get-PlistValue $generic 'SystemUUID').InnerText;$parsedGuid=[Guid]::Empty;if(-not[Guid]::TryParse($uuidValue,[ref]$parsedGuid)-or$parsedGuid-eq[Guid]::Empty){throw "PlatformInfo/Generic/SystemUUID is not a non-zero UUID: $uuidValue"}
    $rom=Get-PlistValue $generic 'ROM';if($null-eq $rom -or $rom.Name-ne 'data' -or [string]::IsNullOrWhiteSpace($rom.InnerText)){throw 'PlatformInfo/Generic/ROM is missing or empty.'};try{$romBytes=[Convert]::FromBase64String(($rom.InnerText-replace '\s',''))}catch{throw 'PlatformInfo/Generic/ROM is not valid Base64 plist data.'};if($romBytes.Length-ne 6){throw "PlatformInfo/Generic/ROM must contain exactly 6 bytes; found $($romBytes.Length)."}
    $platform=Get-PlistDictionary $root @('PlatformInfo');if($null-eq $platform){throw 'PlatformInfo dictionary is missing.'}
    $automatic=Get-PlistValue $platform 'Automatic';if($null-eq $automatic -or $automatic.Name-ne 'true'){throw 'PlatformInfo/Automatic must be true for first boot.'}
    foreach($name in @('UpdateDataHub','UpdateNVRAM','UpdateSMBIOS')){$value=Get-PlistValue $platform $name;if($null-eq $value -or $value.Name-ne 'true'){throw "PlatformInfo/$name must be true for first boot."}}
    $security=Get-PlistDictionary $root @('Misc','Security');if($null-eq $security){throw 'Misc/Security dictionary is missing.'};$secureBootModel=Get-PlistValue $security 'SecureBootModel';if($null-eq $secureBootModel -or $secureBootModel.Name-ne 'string' -or $secureBootModel.InnerText-ne 'Disabled'){throw 'Misc/Security/SecureBootModel must be Disabled for the generic first-boot path.'}
    if(-not(Test-Path -LiteralPath $hfsPlusPath -PathType Leaf)){throw "UEFI driver HfsPlus.efi is staged at the required path but the file is missing: $hfsPlusPath"}
    $uefi=Get-PlistDictionary $root @('UEFI');if($null-eq $uefi){throw 'UEFI dictionary is missing.'};$drivers=Get-PlistValue $uefi 'Drivers';if($null-eq $drivers -or $drivers.Name-ne 'array'){throw 'UEFI/Drivers array is missing.'}
    $invalidEntries=@($drivers.ChildNodes|Where-Object{$_.NodeType-eq 'Element' -and $_.Name-ne 'dict'});if($invalidEntries.Count-gt 0){throw "UEFI/Drivers contains $($invalidEntries.Count) non-dictionary entr(y/ies); OpenCore requires driver entries to use dictionaries."}
    $hfsEntry=Get-PlistArrayDictionaryByPath ([System.Xml.XmlElement]$drivers) 'HfsPlus.efi';if($null-eq $hfsEntry){throw 'UEFI/Drivers does not contain a dictionary entry referencing HfsPlus.efi.'}
    $hfsEnabled=Get-PlistValue $hfsEntry 'Enabled';if($null-eq $hfsEnabled -or $hfsEnabled.Name-ne 'true'){throw 'UEFI/Drivers/HfsPlus.efi must be enabled.'}
    return [ordered]@{platformInfoAutomatic=$true;systemProductNamePresent=$true;systemSerialNumberPresent=$true;mlbPresent=$true;systemUuidValid=$true;romBytes=$romBytes.Length;platformInfoUpdatesEnabled=$true;secureBootModel=$secureBootModel.InnerText;hfsPlusPresent=$true;hfsPlusEnabled=$true;hfsPlusPath='build/efi/EFI/OC/Drivers/HfsPlus.efi'}
}
try{
    $step++;Write-DevintoshProgress $step $totalSteps 'Checking OpenCore candidate and selected macOS version profile';$profile=Get-DevintoshVersionProfile;$config=Get-DevintoshOpenCoreProfile;if(-not(Test-Path -LiteralPath $configPath)){ $EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND;throw "OpenCore config.plist not found: $configPath" };Write-DevintoshStepLog $step "$($profile.macOSFamily) validation target is OpenCore $($config.version)." 'PASS'
    $step++;Write-DevintoshProgress $step $totalSteps 'Preparing isolated ocvalidate workspace';if(-not(Test-Path -LiteralPath $toolRoot)){New-Item -ItemType Directory -Path $toolRoot -Force|Out-Null};if(Test-Path -LiteralPath $extractRoot){Remove-Item -LiteralPath $extractRoot -Recurse -Force};Write-DevintoshStepLog $step 'Validation workspace prepared.' 'PASS'
    $step++;Write-DevintoshProgress $step $totalSteps "Downloading pinned OpenCore $($config.version) release for validation";Invoke-WebRequest -Uri ([string]$config.releaseUrl) -UseBasicParsing -OutFile $archivePath;if(-not(Test-Path -LiteralPath $archivePath)){$EXIT_CODE=$script:EXIT_DEPENDENCY_FAILURE;throw 'OpenCore validation archive was not downloaded.'};Write-DevintoshStepLog $step "Pinned OpenCore $($config.version) release downloaded." 'PASS'
    $step++;Write-DevintoshProgress $step $totalSteps 'Verifying pinned OpenCore release integrity';$actualSha=Get-FileSha256 $archivePath;$expectedSha=([string]$config.releaseSha256).ToLowerInvariant();if($actualSha-ne$expectedSha){$EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE;throw "OpenCore validation archive SHA-256 mismatch. Expected $expectedSha; received $actualSha."};Write-DevintoshStepLog $step "OpenCore release SHA-256 verified: $actualSha." 'PASS'
    $step++;Write-DevintoshProgress $step $totalSteps "Extracting OpenCore $($config.version) ocvalidate utility";Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot -Force;$candidate=Join-Path $extractRoot 'Utilities\ocvalidate\ocvalidate.exe';if(-not(Test-Path -LiteralPath $candidate)){$EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE;throw "Pinned OpenCore archive is missing Utilities/ocvalidate/ocvalidate.exe: $candidate"};Copy-Item -LiteralPath $candidate -Destination $validatorPath -Force;Write-DevintoshStepLog $step 'Pinned ocvalidate utility extracted from the same OpenCore release.' 'PASS'
    $step++;Write-DevintoshProgress $step $totalSteps 'Checking first-boot semantic prerequisites';$document=New-Object System.Xml.XmlDocument;$document.PreserveWhitespace=$true;$document.Load($configPath);$semantic=Test-FirstBootPrerequisites $document;Write-DevintoshStepLog $step 'SMBIOS identity, PlatformInfo updates, SecureBootModel and schema-valid HfsPlus staging passed pre-boot checks.' 'PASS'
    $step++;Write-DevintoshProgress $step $totalSteps "Validating generated config.plist with OpenCore $($config.version) ocvalidate";& $validatorPath $configPath;$validatorExitCode=$LASTEXITCODE;if($validatorExitCode-ne 0){$EXIT_CODE=$script:EXIT_VALIDATION_FAILURE;throw "ocvalidate rejected config.plist with exit code $validatorExitCode."};Write-DevintoshStepLog $step "ocvalidate $($config.version) accepted the generated config.plist artifact directly." 'PASS'
    $step++;Write-DevintoshProgress $step $totalSteps 'Writing OpenCore validation report';$report=[ordered]@{schemaVersion=5;generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture);targetId=[string]$profile.id;macOSFamily=[string]$profile.macOSFamily;macOSMajorVersion=[int]$profile.macOSMajorVersion;validator='OpenCorePkg Utilities/ocvalidate';openCoreVersion=[string]$config.version;openCoreTag=[string]$config.tag;releaseSha256=$actualSha;configPath='build/efi/EFI/OC/config.plist';status='Valid';validatorExitCode=[int]$validatorExitCode;validationTarget='generated-artifact-direct';firstBootPrerequisites=$semantic};$report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $reportPath -Encoding UTF8;if(Test-Path -LiteralPath $extractRoot){Remove-Item -LiteralPath $extractRoot -Recurse -Force};if(Test-Path -LiteralPath $archivePath){Remove-Item -LiteralPath $archivePath -Force};Write-DevintoshStepLog $step "OpenCore $($config.version) validation report written." 'PASS';Complete-DevintoshProgress 'OpenCore config validation complete';exit $script:EXIT_SUCCESS
}catch{if($EXIT_CODE-eq $script:EXIT_SUCCESS){$EXIT_CODE=$script:EXIT_VALIDATION_FAILURE};Write-DevintoshStepLog $step "OpenCore validation failed: $($_.Exception.Message)" 'FAIL';Write-DevintoshLog 'ERROR' $_.Exception.ToString();exit $EXIT_CODE}
