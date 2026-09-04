#requires -Version 5.1
<#
.SYNOPSIS
    Applies first-boot OpenCore security settings required for Recovery bootstrap.
.DESCRIPTION
    The OpenCore sample defaults SecureBootModel to Default. On a generic PC with
    no native Apple Secure Boot identity, OpenCore can attempt Secure Boot processing
    and fail with: "Grabbed zero system-id for SB, this is not allowed".

    First-boot Devintosh configuration deliberately disables SecureBootModel. This is
    not a hardware spoof and does not alter SMBIOS identity. It is a conservative
    bootstrap setting for the Recovery/installer stage. A future post-install policy
    may re-enable a validated SecureBootModel after native validation.

    This script mutates only generated build/EFI state and is safe to rerun.
.PARAMETER Force
    Replace an existing generated configuration atomically.
#>
[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\console.ps1"
. "$PSScriptRoot\lib\logging.ps1"
. "$PSScriptRoot\lib\progress.ps1"
. "$PSScriptRoot\lib\rollback.ps1"

$EXIT_CODE=$script:EXIT_SUCCESS
$step=0
$totalSteps=4
$configPath=Join-Path $script:BuildRoot 'efi\EFI\OC\config.plist'
$reportPath=Join-Path $script:BuildRoot 'opencore\first-boot-config-report.json'

function Get-PlistDict {
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Root,[Parameter(Mandatory)][string[]]$Path)
    $current=$Root
    foreach($name in $Path){
        $keys=@($current.ChildNodes|Where-Object{$_.NodeType -eq 'Element' -and $_.Name -eq 'key' -and $_.InnerText -eq $name})
        if($keys.Count -gt 1){throw "Duplicate plist key: $name"}
        if($keys.Count -eq 0){
            $key=$current.OwnerDocument.CreateElement('key');$key.InnerText=$name;[void]$current.AppendChild($key)
            $dict=$current.OwnerDocument.CreateElement('dict');[void]$current.AppendChild($dict);$current=$dict
        }else{
            $value=$keys[0].NextSibling;while($null -ne $value -and $value.NodeType -ne 'Element'){$value=$value.NextSibling}
            if($null -eq $value -or $value.Name -ne 'dict'){throw "Plist path '$name' is not a dictionary."}
            $current=[System.Xml.XmlElement]$value
        }
    }
    return $current
}
function Set-PlistString {
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Dict,[Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][string]$Value)
    $keys=@($Dict.ChildNodes|Where-Object{$_.NodeType -eq 'Element' -and $_.Name -eq 'key' -and $_.InnerText -eq $Name})
    if($keys.Count -gt 1){throw "Duplicate plist key: $Name"}
    if($keys.Count -eq 0){$key=$Dict.OwnerDocument.CreateElement('key');$key.InnerText=$Name;[void]$Dict.AppendChild($key)}else{$key=$keys[0]}
    $old=$key.NextSibling;while($null -ne $old -and $old.NodeType -ne 'Element'){$old=$old.NextSibling};if($null -ne $old){[void]$Dict.RemoveChild($old)}
    $node=$Dict.OwnerDocument.CreateElement('string');$node.InnerText=$Value;[void]$key.ParentNode.InsertAfter($node,$key)
}
function Save-PlistAtomic {
    param([Parameter(Mandatory)][System.Xml.XmlDocument]$Xml,[Parameter(Mandatory)][string]$Path)
    $temp="$Path.firstboot.tmp"
    if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force}
    $settings=New-Object System.Xml.XmlWriterSettings;$settings.Encoding=New-Object System.Text.UTF8Encoding($false);$settings.Indent=$true;$settings.OmitXmlDeclaration=$false
    $writer=[System.Xml.XmlWriter]::Create($temp,$settings);try{$Xml.Save($writer)}finally{$writer.Dispose()}
    if(-not(Test-Path -LiteralPath $temp)){throw 'Failed to serialize first-boot OpenCore configuration.'}
    Move-Item -LiteralPath $temp -Destination $Path -Force
}
try{
    Start-DevintoshTransaction
    $step++;Write-DevintoshProgress $step $totalSteps 'Checking generated OpenCore configuration';if(-not(Test-IsAdministrator)){$EXIT_CODE=$script:EXIT_INSUFFICIENT_PRIVILEGES;throw 'Administrator privileges are required.'};if(-not(Test-Path -LiteralPath $configPath -PathType Leaf)){$EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND;throw "OpenCore config.plist not found: $configPath"};Write-DevintoshStepLog $step 'Generated OpenCore configuration is available.' 'PASS'
    $step++;Write-DevintoshProgress $step $totalSteps 'Disabling SecureBootModel for generic first-boot Recovery';$document=New-Object System.Xml.XmlDocument;$document.PreserveWhitespace=$true;$document.Load($configPath);$root=$document.SelectSingleNode('/plist/dict');if($null -eq $root){$EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE;throw 'Invalid OpenCore plist root.'};$security=Get-PlistDict ([System.Xml.XmlElement]$root) @('Misc','Security');$backup="$configPath.firstboot-backup";Copy-Item -LiteralPath $configPath -Destination $backup -Force;Add-DevintoshRollbackAction -Name 'Restore OpenCore config before first-boot security change' -Action {Copy-Item -LiteralPath $backup -Destination $configPath -Force};Set-PlistString $security 'SecureBootModel' 'Disabled';Save-PlistAtomic $document $configPath;Write-DevintoshStepLog $step 'SecureBootModel set to Disabled for the first-boot Recovery path.' 'PASS'
    $step++;Write-DevintoshProgress $step $totalSteps 'Writing first-boot configuration report';$report=[ordered]@{schemaVersion=1;generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture);status='Applied';secureBootModel='Disabled';scope='first-boot-recovery';reason='Avoid Secure Boot model system-id dependency before a validated Apple SMBIOS/Secure Boot identity exists.';configPath='build/efi/EFI/OC/config.plist'};$report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $reportPath -Encoding UTF8;Write-DevintoshStepLog $step 'First-boot configuration report written.' 'PASS'
    $step++;Write-DevintoshProgress $step $totalSteps 'Finalizing first-boot configuration';Complete-DevintoshTransaction;Complete-DevintoshProgress 'First-boot OpenCore configuration complete';exit $script:EXIT_SUCCESS
}catch{Write-DevintoshStepLog $step "First-boot configuration failed: $($_.Exception.Message)" 'FAIL';try{$ok=Invoke-DevintoshRollback;if(-not$ok){$EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE}}catch{$EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE};if($EXIT_CODE -eq $script:EXIT_SUCCESS){$EXIT_CODE=$script:EXIT_GENERAL_FAILURE};exit $EXIT_CODE}
