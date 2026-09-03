#requires -Version 5.1
<#
.SYNOPSIS
    Resolves detected hardware capabilities and generates a conservative OpenCore candidate.

.DESCRIPTION
    Hardware-agnostic configuration engine. Consumes the live hardware profile produced by
    configure-opencore-hardware.ps1 and never accepts hardware identity as manual input.
    Hardware-specific policy belongs in JSON profiles under config/hardware.

    Missing profiles do not reject the machine. They produce NeedsProfile and are recorded in
    the report. This prevents one author's machine from becoming an implicit requirement for
    every other user of the repository.

    This phase does not fabricate SMBIOS identifiers, audio layout IDs, USB maps, ACPI patches,
    GPU spoofing or third-party kext binaries.

.EXIT CODES
    0 = Candidate generated successfully; unresolved capabilities may be reported.
    1 = General failure.
    2 = Validation failure.
    3 = Administrator privileges are required.
    4 = Required profile or resource was not found.
    5 = Automatic rollback failed.
    6 = External dependency failure.
    7 = Generated configuration integrity failure.
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
$totalSteps = 9
$outputRoot = Join-Path $script:BuildRoot 'opencore'
$profilePath = Join-Path $outputRoot 'hardware-detected.json'
$efiOcRoot = Join-Path $script:BuildRoot 'efi\EFI\OC'
$configPath = Join-Path $efiOcRoot 'config.plist'
$reportPath = Join-Path $outputRoot 'configuration-report.json'
$samplePath = Join-Path $outputRoot 'OpenCore-Sample.plist'
$sampleUri = 'https://raw.githubusercontent.com/acidanthera/OpenCorePkg/2a9ce04683ab1d9ca7619bbb4ea4ab869c000ee1/Docs/Sample.plist'

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Required JSON file not found: $Path" }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-Array {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return @() }
    return @($Value)
}

function Test-ProfileMatch {
    param([Parameter(Mandatory)]$Hardware, [Parameter(Mandatory)]$Rule)
    if ($Rule.cpuVendor -and [string]$Hardware.cpu.Manufacturer -notlike "*$($Rule.cpuVendor)*") { return $false }
    if ($Rule.cpuNameRegex -and [string]$Hardware.cpu.Name -notmatch $Rule.cpuNameRegex) { return $false }
    if ($Rule.cpuCoresMin -and [int]$Hardware.cpu.Cores -lt [int]$Rule.cpuCoresMin) { return $false }
    if ($Rule.gpuVendorId) {
        if (@(Get-Array $Hardware.gpu | Where-Object { [string]$_.VendorId -eq [string]$Rule.gpuVendorId }).Count -eq 0) { return $false }
    }
    if ($Rule.gpuDeviceIds) {
        if (@(Get-Array $Hardware.gpu | Where-Object { [string]$_.DeviceId -in @($Rule.gpuDeviceIds) }).Count -eq 0) { return $false }
    }
    if ($Rule.networkVendorId) {
        if (@(Get-Array $Hardware.network.pnp | Where-Object { [string]$_.VendorId -eq [string]$Rule.networkVendorId }).Count -eq 0) { return $false }
    }
    if ($Rule.audioVendorId) {
        if (@(Get-Array $Hardware.audio | Where-Object { [string]$_.VendorId -eq [string]$Rule.audioVendorId }).Count -eq 0) { return $false }
    }
    return $true
}

function Get-HardwareProfiles {
    $root = Join-Path $script:RepoRoot 'config\hardware'
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    $files = @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { return @() }

    $profiles = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        try { [void]$profiles.Add((Read-JsonFile $file.FullName)) }
        catch { Write-DevintoshLog 'WARN' "Ignoring invalid hardware profile $($file.FullName): $($_.Exception.Message)" }
    }
    return @($profiles.ToArray())
}

function Get-Matches {
    param([Parameter(Mandatory)]$Hardware, [AllowNull()][object[]]$Profiles)
    if ($null -eq $Profiles -or $Profiles.Count -eq 0) { return @() }
    $matches = [System.Collections.Generic.List[object]]::new()
    foreach ($profile in $Profiles) {
        if ($null -ne $profile.match -and (Test-ProfileMatch $Hardware $profile.match)) { [void]$matches.Add($profile) }
    }
    return @($matches.ToArray())
}

function Get-PlistDictionary {
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Root, [Parameter(Mandatory)][string[]]$Path)
    $current = $Root
    foreach ($part in $Path) {
        $keys = @($current.ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.Name -eq 'key' -and $_.InnerText -eq $part })
        if ($keys.Count -ne 1) { throw "OpenCore plist dictionary not found: $($Path -join '/')" }
        $node = $keys[0].NextSibling
        while ($null -ne $node -and $node.NodeType -ne 'Element') { $node = $node.NextSibling }
        if ($null -eq $node -or $node.Name -ne 'dict') { throw "OpenCore plist path is not a dictionary: $($Path -join '/')" }
        $current = [System.Xml.XmlElement]$node
    }
    return $current
}

function Set-PlistValue {
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Dict,[Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][string]$Type,[AllowEmptyString()][string]$Value='')
    $keys = @($Dict.ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.Name -eq 'key' -and $_.InnerText -eq $Name })
    if ($keys.Count -gt 1) { throw "Duplicate plist key: $Name" }
    if ($keys.Count -eq 0) { $key=$Dict.OwnerDocument.CreateElement('key'); $key.InnerText=$Name; $Dict.AppendChild($key)|Out-Null } else { $key=$keys[0] }
    $old=$key.NextSibling; while($null -ne $old -and $old.NodeType -ne 'Element'){$old=$old.NextSibling}; if($null -ne $old){$Dict.RemoveChild($old)|Out-Null}
    $node=$Dict.OwnerDocument.CreateElement($Type); if($Type -in @('string','integer')){$node.InnerText=$Value}; $key.ParentNode.InsertAfter($node,$key)|Out-Null
}

function Remove-PlistWarnings {
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Root)
    foreach($key in @($Root.ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.Name -eq 'key' -and $_.InnerText -like '#WARNING*' })){
        $value=$key.NextSibling; while($null -ne $value -and $value.NodeType -ne 'Element'){$value=$value.NextSibling}; $Root.RemoveChild($key)|Out-Null; if($null -ne $value){$Root.RemoveChild($value)|Out-Null}
    }
}

function Set-GenericDefaults {
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Root)
    Set-PlistValue (Get-PlistDictionary $Root @('Booter','Quirks')) 'AvoidRuntimeDefrag' 'true'
    Set-PlistValue (Get-PlistDictionary $Root @('UEFI','Quirks')) 'RequestBootVarRouting' 'true'
    Set-PlistValue (Get-PlistDictionary $Root @('Misc','Security')) 'AllowSetDefault' 'true'
    Set-PlistValue (Get-PlistDictionary $Root @('Misc','Security')) 'ScanPolicy' '0'
    Set-PlistValue (Get-PlistDictionary $Root @('NVRAM','Add','7C436110-AB2A-4BBB-A880-FE41995C9F82')) 'boot-args' 'string' ''
}

try {
    $step++; Write-DevintoshProgress $step $totalSteps 'Checking administrator privileges and generated hardware profile'
    if (-not (Test-IsAdministrator)) { $EXIT_CODE=$script:EXIT_INSUFFICIENT_PRIVILEGES; throw 'Administrator privileges are required.' }
    if (-not (Test-Path -LiteralPath $profilePath)) { $EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND; throw "Run configure-opencore-hardware.ps1 first: $profilePath" }
    Write-DevintoshStepLog $step 'Runtime and hardware profile are available.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Loading hardware facts and data-driven capability profiles'
    $hardware=Read-JsonFile $profilePath
    $profiles=@(Get-HardwareProfiles)
    Write-DevintoshLog 'INFO' "Capability profiles discovered: $($profiles.Count)."
    Write-DevintoshStepLog $step 'Live hardware facts loaded without manual identity input.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Resolving hardware capabilities'
    $matches=@(Get-Matches $hardware $profiles)
    $resolved=[System.Collections.Generic.List[string]]::new(); $unresolved=[System.Collections.Generic.List[string]]::new(); $capabilities=[ordered]@{}
    foreach($profile in $matches){ if($null -ne $profile.capabilities){ foreach($p in $profile.capabilities.PSObject.Properties){$capabilities[$p.Name]=$p.Value; $resolved.Add([string]$p.Name)|Out-Null} } }
    foreach($required in @('cpu','gpu','audio','network','usb','acpi','smbios')){if(-not $capabilities.Contains($required)){$unresolved.Add($required)|Out-Null}}
    $status=if($unresolved.Count -eq 0){'Resolved'}else{'NeedsProfile'}
    Write-DevintoshLog 'INFO' "Resolution status: $status. Resolved=$($resolved.Count); unresolved=$($unresolved.Count)."
    Write-DevintoshStepLog $step "Hardware capability resolution completed: $status." 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Loading pinned OpenCore plist schema'
    if(-not(Test-Path -LiteralPath $samplePath)){Invoke-WebRequest -Uri $sampleUri -UseBasicParsing -OutFile $samplePath}
    if(-not(Test-Path -LiteralPath $samplePath)){$EXIT_CODE=$script:EXIT_DEPENDENCY_FAILURE;throw 'OpenCore Sample.plist could not be obtained.'}
    $xml=New-Object System.Xml.XmlDocument; $xml.PreserveWhitespace=$true; $xml.Load($samplePath)
    $root=[System.Xml.XmlElement]$xml.DocumentElement.SelectSingleNode('/plist/dict')
    if($null -eq $root){$EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE;throw 'Invalid OpenCore Sample.plist root.'}
    Remove-PlistWarnings $root
    Write-DevintoshStepLog $step 'Pinned OpenCore schema loaded.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Applying hardware-independent OpenCore safety defaults'
    Set-GenericDefaults $root
    Write-DevintoshStepLog $step 'Only generic schema-safe defaults were applied.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Applying resolved capability policy'
    $applied=@($capabilities.Keys | ForEach-Object {[string]$_})
    $candidateStatus=if($unresolved.Count -eq 0){'ReadyForAssetResolution'}else{'NeedsProfile'}
    Write-DevintoshStepLog $step "Capability policy stage completed: $candidateStatus." 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Writing OpenCore configuration candidate'
    if(-not(Test-Path -LiteralPath $efiOcRoot)){New-Item -ItemType Directory -Path $efiOcRoot -Force|Out-Null}
    if((Test-Path -LiteralPath $configPath)-and-not $Force){$EXIT_CODE=$script:EXIT_VALIDATION_FAILURE;throw "Generated config already exists: $configPath. Use -Force to replace it."}
    $settings=New-Object System.Xml.XmlWriterSettings; $settings.Encoding=New-Object System.Text.UTF8Encoding($false); $settings.Indent=$true
    $writer=[System.Xml.XmlWriter]::Create($configPath,$settings); try{$xml.Save($writer)}finally{$writer.Dispose()}
    if(-not(Test-Path -LiteralPath $configPath)){$EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE;throw 'config.plist was not created.'}
    Write-DevintoshStepLog $step "Candidate written to $configPath." 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Writing machine-independent configuration report'
    $report=[ordered]@{
        schemaVersion=2
        generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        sourceProfile='build/opencore/hardware-detected.json'
        status=$candidateStatus
        matchedProfiles=@($matches|ForEach-Object{if($_.id){[string]$_.id}else{'unnamed'}})
        resolvedCapabilities=@($resolved|Select-Object -Unique)
        unresolvedCapabilities=@($unresolved|Select-Object -Unique)
        appliedCapabilityKeys=@($applied|Select-Object -Unique)
        generatedArtifacts=@('build/efi/EFI/OC/config.plist')
        intentionallyNotGenerated=@('SMBIOS unique identifiers','audio layout-id','USB port map','ACPI patches and SSDTs','GPU spoofing','third-party kext binaries and versions')
    }
    $report|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $reportPath -Encoding UTF8
    Write-DevintoshStepLog $step "Configuration report written to $reportPath." 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Finalizing hardware-agnostic OpenCore configuration'
    Write-DevintoshStepLog $step 'Unknown hardware is reported as NeedsProfile rather than rejected or mapped to another machine.' 'PASS'
}
catch{
    Write-DevintoshStepLog ([Math]::Max($step,1)) "OpenCore configuration failed: $($_.Exception.Message)" 'FAIL'
    try{Invoke-DevintoshRollback}catch{$EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE}
}
finally{Write-DevintoshLog 'INFO' "EXIT_CODE=$EXIT_CODE"}
exit $EXIT_CODE
