#requires -Version 5.1
<#
.SYNOPSIS
    Resolves detected hardware capabilities and generates a conservative OpenCore candidate.
.DESCRIPTION
    Hardware-agnostic and data-driven. Hardware identity is read only from the generated
    Windows inventory. Hardware-specific policy belongs in JSON profiles under config/hardware.
    Unknown hardware is reported as NeedsProfile; detected but unsafe/unvalidated capabilities
    are reported as NeedsValidation. This phase never fabricates SMBIOS identifiers, audio
    layout IDs, USB maps, ACPI patches, GPU spoofing, or third-party kext binaries.
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
$totalSteps = 9
$outputRoot = Join-Path $script:BuildRoot 'opencore'
$hardwarePath = Join-Path $outputRoot 'hardware-detected.json'
$efiOcRoot = Join-Path $script:BuildRoot 'efi\EFI\OC'
$configPath = Join-Path $efiOcRoot 'config.plist'
$reportPath = Join-Path $outputRoot 'configuration-report.json'
$resolutionPath = Join-Path $outputRoot 'hardware-resolution.json'
$samplePath = Join-Path $outputRoot 'OpenCore-Sample.plist'
$sampleUri = 'https://raw.githubusercontent.com/acidanthera/OpenCorePkg/1.0.7/Docs/Sample.plist'

function Get-Prop {
    param([AllowNull()][object]$Object,[Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}
function Get-ArraySafe {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return @() }
    return @($Value)
}
function Test-Equal {
    param([AllowNull()]$Actual,[AllowNull()]$Expected)
    if ($null -eq $Actual -or $null -eq $Expected) { return $false }
    return ([string]$Actual).Trim().Equals(([string]$Expected).Trim(),[StringComparison]::OrdinalIgnoreCase)
}
function Test-IdentityCollection {
    param([AllowNull()]$Items,[AllowNull()]$VendorId,[AllowNull()]$DeviceIds,[AllowNull()]$SubsystemIds)
    $wantedDevices = @(Get-ArraySafe $DeviceIds | ForEach-Object {[string]$_})
    $wantedSubsystems = @(Get-ArraySafe $SubsystemIds | ForEach-Object {[string]$_})
    foreach ($item in @(Get-ArraySafe $Items)) {
        if ($VendorId -and -not (Test-Equal (Get-Prop $item 'VendorId') $VendorId)) { continue }
        if ($wantedDevices.Count -gt 0 -and -not (@($wantedDevices | Where-Object { Test-Equal (Get-Prop $item 'DeviceId') $_ }).Count -gt 0)) { continue }
        if ($wantedSubsystems.Count -gt 0 -and -not (@($wantedSubsystems | Where-Object { Test-Equal (Get-Prop $item 'SubsystemId') $_ }).Count -gt 0)) { continue }
        return $true
    }
    return $false
}
function Test-Rule {
    param([Parameter(Mandatory)]$Hardware,[Parameter(Mandatory)]$Rule)
    $cpu = Get-Prop $Hardware 'cpu'; $platform = Get-Prop $Hardware 'platform'; $network = Get-Prop $Hardware 'network'; $usb = Get-Prop $Hardware 'usb'
    $checks = @(
        @('cpuVendor',(Get-Prop $cpu 'Manufacturer'),$null),
        @('cpuName',(Get-Prop $cpu 'Name'),$null),
        @('platformManufacturer',(Get-Prop $platform 'Manufacturer'),$null),
        @('platformModel',(Get-Prop $platform 'Model'),$null),
        @('motherboardManufacturer',(Get-Prop $platform 'MotherboardManufacturer'),$null),
        @('motherboardProduct',(Get-Prop $platform 'MotherboardProduct'),$null)
    )
    foreach ($check in $checks) {
        $expected = Get-Prop $Rule $check[0]
        if ($null -ne $expected -and -not (Test-Equal $check[1] $expected)) { return $false }
    }
    $regex = Get-Prop $Rule 'cpuNameRegex'; if ($null -ne $regex -and [string](Get-Prop $cpu 'Name') -notmatch [string]$regex) { return $false }
    $regex = Get-Prop $Rule 'platformModelRegex'; if ($null -ne $regex -and [string](Get-Prop $platform 'Model') -notmatch [string]$regex) { return $false }
    $min = Get-Prop $Rule 'cpuCoresMin'; if ($null -ne $min -and [int](Get-Prop $cpu 'Cores') -lt [int]$min) { return $false }
    $min = Get-Prop $Rule 'cpuThreadsMin'; if ($null -ne $min -and [int](Get-Prop $cpu 'Threads') -lt [int]$min) { return $false }
    $gpuVendor = Get-Prop $Rule 'gpuVendorId'; $gpuDevices = Get-Prop $Rule 'gpuDeviceIds'; $gpuSubsystems = Get-Prop $Rule 'gpuSubsystemIds'
    if ($null -ne $gpuVendor -or $null -ne $gpuDevices -or $null -ne $gpuSubsystems) { if (-not (Test-IdentityCollection (Get-Prop $Hardware 'gpu') $gpuVendor $gpuDevices $gpuSubsystems)) { return $false } }
    $audioVendor = Get-Prop $Rule 'audioVendorId'; $audioDevices = Get-Prop $Rule 'audioDeviceIds'; $audioSubsystems = Get-Prop $Rule 'audioSubsystemIds'
    if ($null -ne $audioVendor -or $null -ne $audioDevices -or $null -ne $audioSubsystems) { if (-not (Test-IdentityCollection (Get-Prop $Hardware 'audio') $audioVendor $audioDevices $audioSubsystems)) { return $false } }
    $networkVendor = Get-Prop $Rule 'networkVendorId'; $networkDevices = Get-Prop $Rule 'networkDeviceIds'; $networkSubsystems = Get-Prop $Rule 'networkSubsystemIds'
    if ($null -ne $networkVendor -or $null -ne $networkDevices -or $null -ne $networkSubsystems) { if (-not (Test-IdentityCollection (Get-Prop $network 'pnp') $networkVendor $networkDevices $networkSubsystems)) { return $false } }
    $usbVendor = Get-Prop $Rule 'usbVendorId'; $usbDevices = Get-Prop $Rule 'usbDeviceIds'; $usbSubsystems = Get-Prop $Rule 'usbSubsystemIds'
    if ($null -ne $usbVendor -or $null -ne $usbDevices -or $null -ne $usbSubsystems) { if (-not (Test-IdentityCollection (Get-Prop $usb 'pnp') $usbVendor $usbDevices $usbSubsystems)) { return $false } }
    $acpiIds = Get-Prop $Rule 'acpiDeviceIds'
    if ($null -ne $acpiIds) {
        $found = $false
        foreach ($device in @(Get-ArraySafe (Get-Prop $Hardware 'acpi'))) {
            foreach ($wanted in @(Get-ArraySafe $acpiIds)) {
                if (Test-Equal (Get-Prop $device 'PnpDeviceId') ([string]$wanted)) { $found=$true; break }
                foreach ($compatible in @(Get-ArraySafe (Get-Prop $device 'CompatibleIds'))) { if (Test-Equal $compatible ([string]$wanted)) { $found=$true; break } }
                if ($found) { break }
            }
            if ($found) { break }
        }
        if (-not $found) { return $false }
    }
    $anyOf = Get-Prop $Rule 'anyOf'
    if ($null -ne $anyOf) { $ok=$false; foreach ($alternative in @(Get-ArraySafe $anyOf)) { if (Test-Rule $Hardware $alternative) { $ok=$true; break } }; if (-not $ok) { return $false } }
    return $true
}
function Read-JsonLocal { param([Parameter(Mandatory)][string]$Path); if (-not (Test-Path -LiteralPath $Path)) { throw "Required JSON file not found: $Path" }; return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
function Get-ProfilesLocal {
    $root = Join-Path $script:RepoRoot 'config\hardware'; $result=[System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue)) {
        try { $profile=Read-JsonLocal $file.FullName; if ($null -ne (Get-Prop $profile 'id') -and $null -ne (Get-Prop $profile 'match')) {[void]$result.Add($profile)} }
        catch { Write-DevintoshLog 'WARN' "Ignoring invalid hardware profile $($file.FullName): $($_.Exception.Message)" }
    }
    return @($result.ToArray())
}
function Get-MatchedProfilesLocal {
    param([Parameter(Mandatory)]$Hardware,[AllowNull()][object[]]$Profiles)
    $result=[System.Collections.Generic.List[object]]::new(); foreach ($profile in @(Get-ArraySafe $Profiles)) { if (Test-Rule $Hardware (Get-Prop $profile 'match')) {[void]$result.Add($profile)} }; return @($result.ToArray())
}
function Get-CapabilityStateLocal {
    param([AllowNull()][object[]]$Profiles)
    $names=@('cpu','gpu','audio','network','usb','acpi','smbios'); $resolved=[System.Collections.Generic.List[string]]::new(); $unresolved=[System.Collections.Generic.List[string]]::new(); $validation=[System.Collections.Generic.List[string]]::new(); $details=[ordered]@{}
    foreach ($name in $names) {
        $providers=[System.Collections.Generic.List[object]]::new(); $reasons=[System.Collections.Generic.List[string]]::new()
        foreach ($profile in @(Get-ArraySafe $Profiles)) { $caps=Get-Prop $profile 'capabilities'; $enabled=Get-Prop $caps $name; if ($null -ne $enabled -and [bool]$enabled) {[void]$providers.Add($profile)} }
        if ($providers.Count -eq 0) {[void]$unresolved.Add($name); continue}
        [void]$resolved.Add($name); $requires=$false
        foreach ($profile in $providers) {
            $id=[string](Get-Prop $profile 'id'); $caps=Get-Prop $profile 'capabilities'
            foreach ($p in @($caps.PSObject.Properties)) { if ($p.Name -match '^requires.*Validation$' -and [bool]$p.Value) {$requires=$true; [void]$reasons.Add(('{0}: {1}' -f $id,$p.Name))} }
            $policy=Get-Prop (Get-Prop $profile 'opencore') 'policy'; if ([string]$policy -eq 'validation-required') {$requires=$true; [void]$reasons.Add(('{0}: opencore.policy=validation-required' -f $id))}
        }
        if ($requires) {[void]$validation.Add($name)}
        $details[$name]=[ordered]@{providers=@($providers|ForEach-Object{[string](Get-Prop $_ 'id')});requiresValidation=$requires;validationReasons=@($reasons|Select-Object -Unique)}
    }
    $status='Resolved'; if ($unresolved.Count -gt 0) {$status='NeedsProfile'} elseif ($validation.Count -gt 0) {$status='NeedsValidation'}
    return [pscustomobject]@{status=$status;resolved=@($resolved|Select-Object -Unique);unresolved=@($unresolved|Select-Object -Unique);needsValidation=@($validation|Select-Object -Unique);capabilities=$details}
}
function Remove-PlistWarningsLocal { param([Parameter(Mandatory)][System.Xml.XmlElement]$Root); foreach ($key in @($Root.ChildNodes|Where-Object{$_.NodeType -eq 'Element' -and $_.Name -eq 'key' -and $_.InnerText -like '#WARNING*'})) {$value=$key.NextSibling; while($null -ne $value -and $value.NodeType -ne 'Element'){$value=$value.NextSibling}; [void]$Root.RemoveChild($key); if($null -ne $value){[void]$Root.RemoveChild($value)}} }
function Set-PlistValueLocal {
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Dict,[Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][ValidateSet('string','integer','boolean','data')][string]$Type,[AllowEmptyString()][string]$Value='')
    $key=@($Dict.ChildNodes|Where-Object{$_.NodeType -eq 'Element' -and $_.Name -eq 'key' -and $_.InnerText -eq $Name}); if($key.Count -gt 1){throw "Duplicate plist key: $Name"}; if($key.Count -eq 0){$key=$Dict.OwnerDocument.CreateElement('key');$key.InnerText=$Name;[void]$Dict.AppendChild($key)}else{$key=$key[0]}
    $old=$key.NextSibling;while($null -ne $old -and $old.NodeType -ne 'Element'){$old=$old.NextSibling};if($null -ne $old){[void]$Dict.RemoveChild($old)}
    if($Type -eq 'boolean'){if($Value -notin @('true','false')){throw "Invalid plist boolean value '$Value'."};$node=$Dict.OwnerDocument.CreateElement($(if($Value -eq 'true'){'true'}else{'false'}))}else{$node=$Dict.OwnerDocument.CreateElement($Type);$node.InnerText=$Value}
    [void]$key.ParentNode.InsertAfter($node,$key)
}
function Add-PlistArrayStringLocal {
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Dict,[Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][string]$Value)
    $keys=@($Dict.ChildNodes|Where-Object{$_.NodeType -eq 'Element' -and $_.Name -eq 'key' -and $_.InnerText -eq $Name})
    if($keys.Count -gt 1){throw "Duplicate plist key: $Name"}
    if($keys.Count -eq 0){$key=$Dict.OwnerDocument.CreateElement('key');$key.InnerText=$Name;$array=$Dict.OwnerDocument.CreateElement('array');[void]$Dict.AppendChild($key);[void]$Dict.AppendChild($array)}
    else{$key=$keys[0];$array=$key.NextSibling;while($null -ne $array -and $array.NodeType -ne 'Element'){$array=$array.NextSibling};if($null -eq $array -or $array.Name -ne 'array'){throw "Plist path '$Name' is not an array."}}
    $existing=@($array.ChildNodes|Where-Object{$_.NodeType -eq 'Element' -and $_.Name -eq 'string' -and $_.InnerText -eq $Value})
    if($existing.Count -eq 0){$item=$Dict.OwnerDocument.CreateElement('string');$item.InnerText=$Value;[void]$array.AppendChild($item)}
}
function Get-PlistDictLocal {
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Root,[Parameter(Mandatory)][string[]]$Path)
    $current=$Root; foreach($name in $Path){$key=@($current.ChildNodes|Where-Object{$_.NodeType -eq 'Element' -and $_.Name -eq 'key' -and $_.InnerText -eq $name});if($key.Count -gt 1){throw "Duplicate plist key: $name"};if($key.Count -eq 0){$k=$current.OwnerDocument.CreateElement('key');$k.InnerText=$name;[void]$current.AppendChild($k);$d=$current.OwnerDocument.CreateElement('dict');[void]$current.AppendChild($d);$current=$d}else{$v=$key[0].NextSibling;while($null -ne $v -and $v.NodeType -ne 'Element'){$v=$v.NextSibling};if($null -eq $v -or $v.Name -ne 'dict'){throw "Plist path '$name' is not a dictionary."};$current=[System.Xml.XmlElement]$v}};return $current
}
function Save-PlistUtf8Atomic {
    param([Parameter(Mandatory)][System.Xml.XmlDocument]$Xml,[Parameter(Mandatory)][string]$Path)
    $tempPath = "$Path.tmp"
    if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $settings.Indent = $true
    $settings.OmitXmlDeclaration = $false
    $writer = [System.Xml.XmlWriter]::Create($tempPath,$settings)
    try { $Xml.Save($writer) } finally { $writer.Dispose() }
    if (-not (Test-Path -LiteralPath $tempPath)) { throw "Failed to serialize OpenCore plist: $tempPath" }
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}
try {
    $step++; Write-DevintoshProgress $step $totalSteps 'Checking administrator privileges and generated hardware profile'; if(-not(Test-IsAdministrator)){$EXIT_CODE=$script:EXIT_INSUFFICIENT_PRIVILEGES;throw 'Administrator privileges are required.'}; if(-not(Test-Path -LiteralPath $hardwarePath)){$EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND;throw "Run configure-opencore-hardware.ps1 first: $hardwarePath"}; Write-DevintoshStepLog $step 'Runtime and hardware profile are available.' 'PASS'
    $step++; Write-DevintoshProgress $step $totalSteps 'Loading hardware facts and data-driven capability profiles'; $hardware=Read-JsonLocal $hardwarePath;$profiles=@(Get-ProfilesLocal);Write-DevintoshLog 'INFO' "Capability profiles discovered: $($profiles.Count).";Write-DevintoshStepLog $step 'Live hardware facts loaded without manual identity input.' 'PASS'
    $step++; Write-DevintoshProgress $step $totalSteps 'Resolving hardware capabilities';$matched=@(Get-MatchedProfilesLocal $hardware $profiles);$state=Get-CapabilityStateLocal $matched;Write-DevintoshLog 'INFO' "Matched profiles: $(@($matched|ForEach-Object{[string](Get-Prop $_ 'id')}) -join ', ').";Write-DevintoshLog 'INFO' "Resolution status: $($state.status). Resolved=$($state.resolved.Count); unresolved=$($state.unresolved.Count); validation=$($state.needsValidation.Count).";Write-DevintoshStepLog $step "Hardware capability resolution completed: $($state.status)." 'PASS'
    $step++; Write-DevintoshProgress $step $totalSteps 'Loading pinned OpenCore plist schema';Invoke-WebRequest -Uri $sampleUri -UseBasicParsing -OutFile $samplePath;if(-not(Test-Path -LiteralPath $samplePath)){$EXIT_CODE=$script:EXIT_DEPENDENCY_FAILURE;throw 'OpenCore Sample.plist could not be obtained.'};$xml=New-Object System.Xml.XmlDocument;$xml.PreserveWhitespace=$true;$xml.Load($samplePath);$root=[System.Xml.XmlElement]$xml.DocumentElement.SelectSingleNode('/plist/dict');if($null -eq $root){$EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE;throw 'Invalid OpenCore Sample.plist root.'};Remove-PlistWarningsLocal $root;Write-DevintoshStepLog $step 'Pinned OpenCore schema loaded.' 'PASS'
    $step++; Write-DevintoshProgress $step $totalSteps 'Applying hardware-independent OpenCore safety defaults';$bootQuirks=Get-PlistDictLocal $root @('Booter','Quirks');$uefiQuirks=Get-PlistDictLocal $root @('UEFI','Quirks');$security=Get-PlistDictLocal $root @('Misc','Security');$nvram=Get-PlistDictLocal $root @('NVRAM','Add','7C436110-AB2A-4BBB-A880-FE41995C9F82');$uefi=Get-PlistDictLocal $root @('UEFI');Add-PlistArrayStringLocal $uefi 'Drivers' 'HfsPlus.efi';Set-PlistValueLocal $bootQuirks 'AvoidRuntimeDefrag' 'boolean' 'true';Set-PlistValueLocal $uefiQuirks 'RequestBootVarRouting' 'boolean' 'true';Set-PlistValueLocal $security 'AllowSetDefault' 'boolean' 'true';Set-PlistValueLocal $security 'Vault' 'string' 'Optional';Set-PlistValueLocal $nvram 'boot-args' 'string' '';Write-DevintoshStepLog $step 'Only generic schema-safe defaults were applied; HfsPlus.efi is declared as a universal UEFI driver and will be staged by the dedicated driver acquisition stage.' 'PASS'
    $step++; Write-DevintoshProgress $step $totalSteps 'Applying resolved capability policy';Write-DevintoshStepLog $step "Capability policy stage completed: $($state.status). Profile-specific fragments are applied by apply-opencore-profiles.ps1." 'PASS'
    $step++; Write-DevintoshProgress $step $totalSteps 'Writing OpenCore configuration candidate';if(-not(Test-Path -LiteralPath $efiOcRoot)){New-Item -ItemType Directory -Path $efiOcRoot -Force|Out-Null};if((Test-Path -LiteralPath $configPath) -and -not $Force){$EXIT_CODE=$script:EXIT_VALIDATION_FAILURE;throw 'Existing config.plist found. Use -Force to replace it.'};Save-PlistUtf8Atomic -Xml $xml -Path $configPath;$resolution=[ordered]@{schemaVersion=1;generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture);sourceHardware='build/opencore/hardware-detected.json';matchedProfiles=@($matched|ForEach-Object{[string](Get-Prop $_ 'id')});status=$state.status;resolvedCapabilities=@($state.resolved);unresolvedCapabilities=@($state.unresolved);needsValidation=@($state.needsValidation);capabilities=$state.capabilities};$resolution|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $resolutionPath -Encoding UTF8;$report=[ordered]@{schemaVersion=2;generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture);sourceProfile='build/opencore/hardware-detected.json';status=$state.status;matchedProfiles=@($matched|ForEach-Object{[string](Get-Prop $_ 'id')});resolvedCapabilities=@($state.resolved);unresolvedCapabilities=@($state.unresolved);needsValidation=@($state.needsValidation);appliedCapabilityKeys=@();generatedArtifacts=@('build/efi/EFI/OC/config.plist');intentionallyNotGenerated=@('SMBIOS unique identifiers','audio layout-id','USB port map','ACPI patches and SSDTs','GPU spoofing','third-party kext binaries and versions','OpenCore vault files')};$report|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $reportPath -Encoding UTF8;Complete-DevintoshTransaction;Write-DevintoshStepLog $step "OpenCore configuration candidate written to $configPath." 'PASS'
    $step++; Write-DevintoshProgress $step $totalSteps 'Finalizing hardware-agnostic OpenCore configuration';Complete-DevintoshProgress 'Finalizing hardware-agnostic OpenCore configuration';Write-DevintoshStepLog $step 'Unknown hardware is reported as NeedsProfile rather than rejected or mapped to another machine.' 'PASS';exit $script:EXIT_SUCCESS
}
catch {Write-DevintoshStepLog $step "OpenCore configuration failed: $($_.Exception.Message)" 'FAIL';Write-DevintoshLog 'ERROR' $_.Exception.ToString();$rollbackOk=Invoke-DevintoshRollback;if(-not $rollbackOk){$EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE};exit $EXIT_CODE}
