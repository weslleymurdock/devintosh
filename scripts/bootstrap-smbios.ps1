#requires -Version 5.1
<#
.SYNOPSIS
    Applies an ephemeral SMBIOS identity required for the first OpenCore boot.
.DESCRIPTION
    This is a bootstrap-only stage. It consumes the already-resolved SMBIOS candidate,
    generates a local synthetic identity, and writes it only to build/EFI config state.
    No generated identity is committed to source control. The identity is intentionally
    unsuitable as a long-term Apple identity and must be replaced by an explicitly
    validated SMBIOS identity before production use of Apple services.

    The stage refuses to guess when there is not exactly one eligible SMBIOS candidate.
    It never invents a Mac model and never writes identity data to config profiles.
.PARAMETER Force
    Replace an existing bootstrap identity in the generated config.plist.
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

$EXIT_CODE=$script:EXIT_SUCCESS
$step=0
$totalSteps=6
$outputRoot=Join-Path $script:BuildRoot 'opencore'
$resolutionPath=Join-Path $outputRoot 'smbios-resolution.json'
$configPath=Join-Path $script:BuildRoot 'efi\EFI\OC\config.plist'
$reportPath=Join-Path $outputRoot 'smbios-bootstrap-report.json'

function Get-Prop { param([AllowNull()][object]$Object,[Parameter(Mandatory)][string]$Name); if($null -eq $Object){return $null};$p=$Object.PSObject.Properties[$Name];if($null -eq $p){return $null};return $p.Value }
function Read-Json { param([Parameter(Mandatory)][string]$Path);if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw "Required JSON file not found: $Path"};return Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json }
function Get-Dict { param([Parameter(Mandatory)][System.Xml.XmlElement]$Root,[Parameter(Mandatory)][string[]]$Path);$current=$Root;foreach($name in $Path){$keys=@($current.ChildNodes|Where-Object{$_.NodeType -eq 'Element' -and $_.Name -eq 'key' -and $_.InnerText -eq $name});if($keys.Count -gt 1){throw "Duplicate plist key: $name"};if($keys.Count -eq 0){$key=$current.OwnerDocument.CreateElement('key');$key.InnerText=$name;[void]$current.AppendChild($key);$dict=$current.OwnerDocument.CreateElement('dict');[void]$current.AppendChild($dict);$current=$dict}else{$value=$keys[0].NextSibling;while($null -ne $value -and $value.NodeType -ne 'Element'){$value=$value.NextSibling};if($null -eq $value -or $value.Name -ne 'dict'){throw "Plist path '$name' is not a dictionary."};$current=[System.Xml.XmlElement]$value}};return $current }
function Set-Value { param([Parameter(Mandatory)][System.Xml.XmlElement]$Dict,[Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][ValidateSet('string','data')][string]$Type,[Parameter(Mandatory)][string]$Value);$keys=@($Dict.ChildNodes|Where-Object{$_.NodeType -eq 'Element' -and $_.Name -eq 'key' -and $_.InnerText -eq $Name});if($keys.Count -gt 1){throw "Duplicate plist key: $Name"};if($keys.Count -eq 0){$key=$Dict.OwnerDocument.CreateElement('key');$key.InnerText=$Name;[void]$Dict.AppendChild($key)}else{$key=$keys[0]};$old=$key.NextSibling;while($null -ne $old -and $old.NodeType -ne 'Element'){$old=$old.NextSibling};if($null -ne $old){[void]$Dict.RemoveChild($old)};$node=$Dict.OwnerDocument.CreateElement($Type);$node.InnerText=$Value;[void]$key.ParentNode.InsertAfter($node,$key) }
function New-Identity {
    param([Parameter(Mandatory)][string]$ProductName)
    $uuid=[Guid]::NewGuid().ToString().ToUpperInvariant()
    $bytes=New-Object byte[] 6
    $rng=[Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $rom=([Convert]::ToBase64String([byte[]]$bytes))
    $alphabet='ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $serialBuilder=New-Object System.Text.StringBuilder
    while($serialBuilder.Length -lt 9){[void]$serialBuilder.Append($alphabet[(Get-Random -Minimum 0 -Maximum $alphabet.Length)])}
    $serial='DEV'+$serialBuilder.ToString()
    while($serial.Length -lt 12){$serial+='X'}
    $mlb=$serial+'DEV01'
    if($mlb.Length -gt 17){$mlb=$mlb.Substring(0,17)}
    return [pscustomobject]@{productName=$ProductName;systemSerialNumber=$serial;mlb=$mlb;systemUuid=$uuid;rom=$rom}
}
try {
    Start-DevintoshTransaction
    $step++;Write-DevintoshProgress $step $totalSteps 'Checking SMBIOS bootstrap prerequisites';if(-not(Test-IsAdministrator)){$EXIT_CODE=$script:EXIT_INSUFFICIENT_PRIVILEGES;throw 'Administrator privileges are required.'};if(-not(Test-Path -LiteralPath $resolutionPath -PathType Leaf)){$EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND;throw "SMBIOS resolution not found: $resolutionPath"};if(-not(Test-Path -LiteralPath $configPath -PathType Leaf)){$EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND;throw "OpenCore config.plist not found: $configPath"};Write-DevintoshStepLog $step 'SMBIOS bootstrap prerequisites are available.' 'PASS'
    $step++;Write-DevintoshProgress $step $totalSteps 'Loading the resolved SMBIOS candidate';$resolution=Read-Json $resolutionPath;$candidates=@(Get-Prop $resolution 'candidates');if($candidates.Count -ne 1){$EXIT_CODE=$script:EXIT_UNSUPPORTED_CONFIGURATION;throw "SMBIOS bootstrap requires exactly one eligible candidate; found $($candidates.Count). No model was guessed."};$candidate=$candidates[0];$productName=[string](Get-Prop $candidate 'productName');if([string]::IsNullOrWhiteSpace($productName)){$EXIT_CODE=$script:EXIT_UNSUPPORTED_CONFIGURATION;throw 'Resolved SMBIOS candidate has no productName.'};Write-DevintoshStepLog $step "Using the sole resolved candidate $productName for ephemeral first-boot identity." 'PASS'
    $step++;Write-DevintoshProgress $step $totalSteps 'Generating ephemeral local SMBIOS identity';$identity=New-Identity -ProductName $productName;Write-DevintoshLog 'INFO' 'Generated an ephemeral SMBIOS identity. It is not written to source control.';Write-DevintoshStepLog $step 'Ephemeral SMBIOS identity generated locally.' 'PASS'
    $step++;Write-DevintoshProgress $step $totalSteps 'Applying ephemeral SMBIOS identity to generated OpenCore config';$document=New-Object System.Xml.XmlDocument;$document.PreserveWhitespace=$true;$document.Load($configPath);$root=$document.SelectSingleNode('/plist/dict');if($null -eq $root){$EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE;throw 'Invalid OpenCore config.plist root.'};$generic=Get-Dict ([System.Xml.XmlElement]$root) @('PlatformInfo','Generic');if((Get-Prop $resolution 'status') -notin @('NeedsValidation','Resolved')){$EXIT_CODE=$script:EXIT_UNSUPPORTED_CONFIGURATION;throw "SMBIOS resolution status does not permit bootstrap: $($resolution.status)"};Set-Value $generic 'SystemProductName' 'string' $identity.productName;Set-Value $generic 'SystemSerialNumber' 'string' $identity.systemSerialNumber;Set-Value $generic 'MLB' 'string' $identity.mlb;Set-Value $generic 'SystemUUID' 'string' $identity.systemUuid;Set-Value $generic 'ROM' 'data' $identity.rom;$backup="$configPath.bootstrap-backup";Copy-Item -LiteralPath $configPath -Destination $backup -Force;Add-DevintoshRollbackAction -Name 'Restore config.plist after SMBIOS bootstrap failure' -Action {Copy-Item -LiteralPath $backup -Destination $configPath -Force};$temp="$configPath.bootstrap.tmp";try{$document.Save($temp);Move-Item -LiteralPath $temp -Destination $configPath -Force}finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}};Write-DevintoshStepLog $step 'Ephemeral SMBIOS identity applied only to generated build output.' 'PASS'
    $step++;Write-DevintoshProgress $step $totalSteps 'Writing non-sensitive SMBIOS bootstrap report';if(-not(Test-Path -LiteralPath $outputRoot -PathType Container)){New-Item -ItemType Directory -Path $outputRoot -Force|Out-Null};$report=[ordered]@{schemaVersion=1;generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture);status='AppliedEphemeral';productName=$identity.productName;uniqueIdentifiersPersistedInRepository=$false;replacementRequiredBeforeLongTermUse=$true;generatedArtifacts=@('build/opencore/smbios-bootstrap-report.json');identity=$null};$report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $reportPath -Encoding UTF8;Write-DevintoshStepLog $step 'Bootstrap report written without exposing generated identifiers.' 'PASS'
    $step++;Write-DevintoshProgress $step $totalSteps 'Finalizing SMBIOS bootstrap';Complete-DevintoshTransaction;Complete-DevintoshProgress 'SMBIOS bootstrap complete';Write-DevintoshStepLog $step 'OpenCore now has a non-zero local SystemUUID and a correctly encoded six-byte ROM for first-boot testing.' 'PASS'
}catch{Write-DevintoshLog 'ERROR' "SMBIOS bootstrap failed: $($_.Exception.Message)";try{$ok=Invoke-DevintoshRollback;if(-not$ok){$EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE}}catch{$EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE};if($EXIT_CODE -eq $script:EXIT_SUCCESS){$EXIT_CODE=$script:EXIT_GENERAL_FAILURE}}
exit $EXIT_CODE
