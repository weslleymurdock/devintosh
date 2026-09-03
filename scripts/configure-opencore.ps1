#requires -Version 5.1
<#
.SYNOPSIS
    Generates a machine-specific OpenCore configuration from live hardware data.

.DESCRIPTION
    Consumes build/opencore/hardware-detected.json and generates EFI/OC/config.plist
    without accepting hardware identity as manual input. The configuration is based
    on the detected CPU, GPU and firmware platform. OpenCore's pinned Sample.plist
    is used as the schema source so the generated plist stays aligned with the
    pinned OpenCore release.

    This phase is intentionally conservative. It enables only settings that can be
    justified from the detected hardware and does not invent audio layout IDs, USB
    maps, ACPI tables, Wi-Fi support, or third-party kext binaries. Missing runtime
    assets are reported as requirements instead of being referenced blindly.

.PARAMETER Force
    Replaces an existing generated config.plist after creating a backup.

.EXIT CODES
    0 = Configuration candidate generated and validated successfully.
    1 = General configuration failure.
    2 = Validation failure.
    3 = Administrator privileges are required.
    4 = Required profile or resource was not found.
    5 = Automatic rollback failed.
    6 = External dependency or network failure.
    7 = Generated configuration integrity failure.
    8 = Unsupported hardware or configuration.
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
$totalSteps = 9
$outputRoot = Join-Path $script:BuildRoot 'opencore'
$profilePath = Join-Path $outputRoot 'hardware-detected.json'
$efiOcRoot = Join-Path $script:BuildRoot 'efi\EFI\OC'
$configPath = Join-Path $efiOcRoot 'config.plist'
$reportPath = Join-Path $outputRoot 'configuration-report.json'
$samplePath = Join-Path $outputRoot 'OpenCore-Sample.plist'
$sampleUri = 'https://raw.githubusercontent.com/acidanthera/OpenCorePkg/2a9ce04683ab1d9ca7619bbb4ea4ab869c000ee1/Docs/Sample.plist'
$openCoreBinary = Join-Path $efiOcRoot 'OpenCore.efi'

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
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    Invoke-WebRequest -Uri $Uri -UseBasicParsing -OutFile $partial
    if (-not (Test-Path -LiteralPath $partial)) { throw "Download did not create $partial" }
    Move-Item -LiteralPath $partial -Destination $Destination -Force
}

function Get-PlistDict {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlElement]$RootDict,
        [Parameter(Mandatory = $true)][string[]]$Path
    )
    $current = $RootDict
    foreach ($segment in $Path) {
        $keys = @($current.ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element -and $_.Name -eq 'key' -and $_.InnerText -eq $segment })
        if ($keys.Count -ne 1) { throw "OpenCore Sample.plist path not found or ambiguous: $($Path -join '/')" }
        $key = $keys[0]
        $node = $key.NextSibling
        while ($null -ne $node -and $node.NodeType -ne [System.Xml.XmlNodeType]::Element) { $node = $node.NextSibling }
        if ($null -eq $node -or $node.Name -ne 'dict') { throw "OpenCore Sample.plist path is not a dictionary: $($Path -join '/')" }
        $current = [System.Xml.XmlElement]$node
    }
    return $current
}

function Get-PlistChild {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlElement]$Dict,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $keys = @($Dict.ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element -and $_.Name -eq 'key' -and $_.InnerText -eq $Name })
    if ($keys.Count -eq 0) { return $null }
    if ($keys.Count -ne 1) { throw "Duplicate plist key: $Name" }
    $node = $keys[0].NextSibling
    while ($null -ne $node -and $node.NodeType -ne [System.Xml.XmlNodeType]::Element) { $node = $node.NextSibling }
    return [System.Xml.XmlElement]$node
}

function Set-PlistScalar {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlElement]$Dict,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('string','integer','true','false')][string]$Type,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Value = ''
    )
    $key = Get-PlistChild -Dict $Dict -Name $Name
    if ($null -eq $key) {
        $key = $Dict.OwnerDocument.CreateElement('key')
        $key.InnerText = $Name
        $Dict.AppendChild($key) | Out-Null
    } else {
        $key = $key.ParentNode.SelectSingleNode("key[.='$Name']")
    }
    $oldValue = $key.NextSibling
    while ($null -ne $oldValue -and $oldValue.NodeType -ne [System.Xml.XmlNodeType]::Element) { $oldValue = $oldValue.NextSibling }
    if ($null -ne $oldValue) { $Dict.RemoveChild($oldValue) | Out-Null }
    $newValue = $Dict.OwnerDocument.CreateElement($Type)
    if ($Type -eq 'string' -or $Type -eq 'integer') { $newValue.InnerText = $Value }
    $key.ParentNode.InsertAfter($newValue, $key) | Out-Null
}

function Set-PlistData {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlElement]$Dict,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )
    $base64 = [Convert]::ToBase64String($Bytes)
    $key = Get-PlistChild -Dict $Dict -Name $Name
    if ($null -eq $key) {
        $key = $Dict.OwnerDocument.CreateElement('key')
        $key.InnerText = $Name
        $Dict.AppendChild($key) | Out-Null
    } else {
        $key = $key.ParentNode.SelectSingleNode("key[.='$Name']")
    }
    $oldValue = $key.NextSibling
    while ($null -ne $oldValue -and $oldValue.NodeType -ne [System.Xml.XmlNodeType]::Element) { $oldValue = $oldValue.NextSibling }
    if ($null -ne $oldValue) { $Dict.RemoveChild($oldValue) | Out-Null }
    $newValue = $Dict.OwnerDocument.CreateElement('data')
    $newValue.InnerText = $base64
    $key.ParentNode.InsertAfter($newValue, $key) | Out-Null
}

function Set-PlistArrayEmpty {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlElement]$Dict,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $key = Get-PlistChild -Dict $Dict -Name $Name
    if ($null -eq $key) {
        $key = $Dict.OwnerDocument.CreateElement('key')
        $key.InnerText = $Name
        $Dict.AppendChild($key) | Out-Null
    } else {
        $key = $key.ParentNode.SelectSingleNode("key[.='$Name']")
    }
    $oldValue = $key.NextSibling
    while ($null -ne $oldValue -and $oldValue.NodeType -ne [System.Xml.XmlNodeType]::Element) { $oldValue = $oldValue.NextSibling }
    if ($null -ne $oldValue) { $Dict.RemoveChild($oldValue) | Out-Null }
    $newValue = $Dict.OwnerDocument.CreateElement('array')
    $key.ParentNode.InsertAfter($newValue, $key) | Out-Null
}

function Set-PlistDataHex {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlElement]$Dict,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Hex
    )
    $clean = $Hex -replace '[^0-9A-Fa-f]', ''
    if (($clean.Length % 2) -ne 0) { throw "Invalid plist data hex for $Name." }
    $bytes = New-Object byte[] ($clean.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($clean.Substring($i * 2, 2), 16) }
    Set-PlistData -Dict $Dict -Name $Name -Bytes $bytes
}

function Remove-PlistWarningKeys {
    param([Parameter(Mandatory = $true)][System.Xml.XmlElement]$RootDict)
    $warnings = @($RootDict.ChildNodes | Where-Object {
        $_.NodeType -eq [System.Xml.XmlNodeType]::Element -and $_.Name -eq 'key' -and $_.InnerText -like '#WARNING*'
    })
    foreach ($warning in $warnings) {
        $value = $warning.NextSibling
        while ($null -ne $value -and $value.NodeType -ne [System.Xml.XmlNodeType]::Element) { $value = $value.NextSibling }
        $RootDict.RemoveChild($warning) | Out-Null
        if ($null -ne $value) { $RootDict.RemoveChild($value) | Out-Null }
    }
}

function New-DeterministicIdentifiers {
    param([Parameter(Mandatory = $true)]$Profile)
    $uuidSource = [string]$Profile.platform.MotherboardManufacturer + '|' + [string]$Profile.platform.MotherboardProduct + '|' + [string]$Profile.platform.BiosVersion + '|' + [string]$Profile.cpu.Name
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $digest = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($uuidSource)) } finally { $sha.Dispose() }
    $uuidBytes = New-Object byte[] 16
    [Array]::Copy($digest, 0, $uuidBytes, 0, 16)
    $uuidBytes[6] = ($uuidBytes[6] -band 0x0F) -bor 0x40
    $uuidBytes[8] = ($uuidBytes[8] -band 0x3F) -bor 0x80
    $uuid = [Guid]::new($uuidBytes).ToString().ToUpperInvariant()
    $serial = 'C02' + (($digest | ForEach-Object { $_.ToString('X2') }) -join '').Substring(0, 9)
    $mlb = ($serial + (($digest | ForEach-Object { $_.ToString('X2') }) -join '').Substring(9, 5)).Substring(0, 17)
    $mac = $null
    foreach ($adapter in @($Profile.network.physicalAdapters)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$adapter.MacAddress)) { $mac = [string]$adapter.MacAddress; break }
    }
    if ([string]::IsNullOrWhiteSpace($mac)) { $mac = '000000000000' }
    $rom = ($mac -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    if ($rom.Length -ne 12) { $rom = (($digest | ForEach-Object { $_.ToString('X2') }) -join '').Substring(0, 12) }
    return [pscustomobject]@{ SystemUUID = $uuid; SystemSerialNumber = $serial; MLB = $mlb; ROM = $rom }
}

function New-KernelAddEntry {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlDocument]$Document,
        [Parameter(Mandatory = $true)][string]$BundlePath,
        [Parameter(Mandatory = $true)][string]$Comment,
        [Parameter(Mandatory = $true)][bool]$Enabled
    )
    $dict = $Document.CreateElement('dict')
    foreach ($pair in @(
        @('Arch', 'string', 'Any'),
        @('BundlePath', 'string', $BundlePath),
        @('Comment', 'string', $Comment),
        @('Enabled', $(if ($Enabled) { 'true' } else { 'false' })),
        @('ExecutablePath', 'string', ''),
        @('MaxKernel', 'string', ''),
        @('MinKernel', 'string', ''),
        @('PlistPath', 'string', 'Contents/Info.plist')
    )) {
        $key = $Document.CreateElement('key'); $key.InnerText = $pair[0]; $dict.AppendChild($key) | Out-Null
        if ($pair[1] -eq 'true' -or $pair[1] -eq 'false') { $value = $Document.CreateElement($pair[1]) }
        else { $value = $Document.CreateElement($pair[1]); $value.InnerText = $pair[2] }
        $dict.AppendChild($value) | Out-Null
    }
    return $dict
}

function Set-KernelAddEntries {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlElement]$Kernel,
        [Parameter(Mandatory = $true)][System.Xml.XmlDocument]$Document,
        [Parameter(Mandatory = $true)][string[]]$KextNames
    )
    $key = Get-PlistChild -Dict $Kernel -Name 'Add'
    if ($null -eq $key) {
        $key = $Document.CreateElement('key'); $key.InnerText = 'Add'; $Kernel.AppendChild($key) | Out-Null
    } else { $key = $key.ParentNode.SelectSingleNode("key[.='Add']") }
    $old = $key.NextSibling
    while ($null -ne $old -and $old.NodeType -ne [System.Xml.XmlNodeType]::Element) { $old = $old.NextSibling }
    if ($null -ne $old) { $Kernel.RemoveChild($old) | Out-Null }
    $array = $Document.CreateElement('array')
    foreach ($name in $KextNames) { $array.AppendChild((New-KernelAddEntry -Document $Document -BundlePath $name -Comment "Detected runtime component: $name" -Enabled $true)) | Out-Null }
    $key.ParentNode.InsertAfter($array, $key) | Out-Null
}

function Set-DriverEntries {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlElement]$Uefi,
        [Parameter(Mandatory = $true)][System.Xml.XmlDocument]$Document,
        [Parameter(Mandatory = $true)][string[]]$DriverNames
    )
    $key = Get-PlistChild -Dict $Uefi -Name 'Drivers'
    if ($null -eq $key) { throw 'OpenCore Sample.plist is missing UEFI/Drivers.' }
    $key = $key.ParentNode.SelectSingleNode("key[.='Drivers']")
    $old = $key.NextSibling
    while ($null -ne $old -and $old.NodeType -ne [System.Xml.XmlNodeType]::Element) { $old = $old.NextSibling }
    if ($null -ne $old) { $Uefi.RemoveChild($old) | Out-Null }
    $array = $Document.CreateElement('array')
    foreach ($name in $DriverNames) {
        $dict = $Document.CreateElement('dict')
        foreach ($entry in @(
            @('Arguments', 'string', ''),
            @('Comment', 'string', "Detected OpenCore driver: $name"),
            @('Enabled', 'true', ''),
            @('LoadEarly', 'false', ''),
            @('Path', 'string', $name)
        )) {
            $k = $Document.CreateElement('key'); $k.InnerText = $entry[0]; $dict.AppendChild($k) | Out-Null
            if ($entry[1] -eq 'true' -or $entry[1] -eq 'false') { $v = $Document.CreateElement($entry[1]) }
            else { $v = $Document.CreateElement($entry[1]); $v.InnerText = $entry[2] }
            $dict.AppendChild($v) | Out-Null
        }
        $array.AppendChild($dict) | Out-Null
    }
    $key.ParentNode.InsertAfter($array, $key) | Out-Null
}

try {
    $step++
    Write-DevintoshProgress $step $totalSteps 'Checking OpenCore configuration prerequisites'
    if (-not (Test-IsAdministrator)) {
        $EXIT_CODE = $script:EXIT_INSUFFICIENT_PRIVILEGES
        throw 'Run configure-opencore.ps1 from an elevated PowerShell session.'
    }
    if (-not (Test-Path -LiteralPath $profilePath)) {
        $EXIT_CODE = $script:EXIT_TARGET_NOT_FOUND
        throw "Hardware detection profile not found: $profilePath"
    }
    if (-not (Test-Path -LiteralPath $openCoreBinary)) {
        $EXIT_CODE = $script:EXIT_TARGET_NOT_FOUND
        throw "OpenCore binary not found: $openCoreBinary"
    }
    Write-DevintoshStepLog $step 'OpenCore configuration prerequisites are available.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Loading detected hardware profile'
    $profile = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$profile.cpu.Name)) {
        $EXIT_CODE = $script:EXIT_VALIDATION_FAILURE
        throw 'Detected hardware profile does not contain a CPU identity.'
    }
    if (@($profile.gpu).Count -eq 0) {
        $EXIT_CODE = $script:EXIT_VALIDATION_FAILURE
        throw 'Detected hardware profile does not contain a GPU identity.'
    }
    Write-DevintoshStepLog $step "Using detected CPU '$($profile.cpu.Name)' and $(@($profile.gpu).Count) GPU(s)." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Resolving Alder Lake and GPU configuration policy'
    $isAlderLake = [string]$profile.cpu.Name -match '(?i)(12th Gen|Alder Lake|i5-12|i7-12|i9-12)'
    $rx550 = @($profile.gpuAnalysis | Where-Object { $_.Rx550.IsRx550 -eq $true })
    $isLexa = $false
    $isBaffin = $false
    if ($rx550.Count -eq 1) {
        $isLexa = [string]$rx550[0].Rx550.Variant -eq 'Lexa'
        $isBaffin = [string]$rx550[0].Rx550.Variant -eq 'Baffin'
    }
    if (-not $isAlderLake) {
        $EXIT_CODE = $script:EXIT_UNSUPPORTED_CONFIGURATION
        throw 'Automatic OpenCore policy currently targets the detected Alder Lake desktop platform.'
    }
    if ($isLexa) {
        $EXIT_CODE = $script:EXIT_UNSUPPORTED_CONFIGURATION
        throw 'RX 550 Lexa was detected. Automatic GPU spoofing is intentionally blocked until the exact PCI identity is validated.'
    }
    if ($rx550.Count -ne 1 -or (-not $isBaffin)) {
        $EXIT_CODE = $script:EXIT_UNSUPPORTED_CONFIGURATION
        throw 'Automatic configuration requires exactly one classified RX 550 Baffin GPU.'
    }
    $smbios = 'MacPro7,1'
    $identifiers = New-DeterministicIdentifiers -Profile $profile
    Write-DevintoshLog 'INFO' "Detected Alder Lake platform; selected SMBIOS policy: $smbios."
    Write-DevintoshLog 'INFO' "Detected RX 550 Baffin; no GPU spoof is required by this policy."
    Write-DevintoshStepLog $step 'Hardware policy resolved without manual hardware input.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Obtaining the pinned OpenCore configuration schema'
    Invoke-DownloadFile -Uri $sampleUri -Destination $samplePath
    if (-not (Test-Path -LiteralPath $samplePath)) {
        $EXIT_CODE = $script:EXIT_DEPENDENCY_FAILURE
        throw 'OpenCore Sample.plist could not be downloaded.'
    }
    Write-DevintoshStepLog $step 'Pinned OpenCore Sample.plist obtained.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Applying machine-specific CPU, SMBIOS and boot policy'
    $document = New-Object System.Xml.XmlDocument
    $document.PreserveWhitespace = $true
    $document.Load($samplePath)
    $rootDict = [System.Xml.XmlElement]$document.SelectSingleNode('/plist/dict')
    if ($null -eq $rootDict) { throw 'OpenCore Sample.plist has no root dictionary.' }
    Remove-PlistWarningKeys -RootDict $rootDict

    $kernel = Get-PlistDict -RootDict $rootDict -Path @('Kernel')
    $emulate = Get-PlistDict -RootDict $rootDict -Path @('Kernel','Emulate')
    Set-PlistDataHex -Dict $emulate -Name 'Cpuid1Data' -Hex '55060A00000000000000000000000000'
    Set-PlistDataHex -Dict $emulate -Name 'Cpuid1Mask' -Hex 'FFFFFFFF000000000000000000000000'
    Set-PlistScalar -Dict $emulate -Name 'MinKernel' -Type string -Value '19.0.0'
    Set-PlistScalar -Dict $emulate -Name 'MaxKernel' -Type string -Value ''
    Set-PlistScalar -Dict $emulate -Name 'DummyPowerManagement' -Type false

    $kernelQuirks = Get-PlistDict -RootDict $rootDict -Path @('Kernel','Quirks')
    Set-PlistScalar -Dict $kernelQuirks -Name 'AppleXcpmCfgLock' -Type true
    Set-PlistScalar -Dict $kernelQuirks -Name 'DisableIoMapper' -Type true
    Set-PlistScalar -Dict $kernelQuirks -Name 'PanicNoKextDump' -Type true
    Set-PlistScalar -Dict $kernelQuirks -Name 'PowerTimeoutKernelPanic' -Type true
    Set-PlistScalar -Dict $kernelQuirks -Name 'ProvideCurrentCpuInfo' -Type true
    Set-PlistScalar -Dict $kernelQuirks -Name 'XhciPortLimit' -Type false
    Set-KernelAddEntries -Kernel $kernel -Document $document -KextNames @()

    $booterQuirks = Get-PlistDict -RootDict $rootDict -Path @('Booter','Quirks')
    Set-PlistScalar -Dict $booterQuirks -Name 'AvoidRuntimeDefrag' -Type true
    Set-PlistScalar -Dict $booterQuirks -Name 'DevirtualiseMmio' -Type true
    Set-PlistScalar -Dict $booterQuirks -Name 'EnableSafeModeSlide' -Type true
    Set-PlistScalar -Dict $booterQuirks -Name 'EnableWriteUnprotector' -Type false
    Set-PlistScalar -Dict $booterQuirks -Name 'ProtectUefiServices' -Type false
    Set-PlistScalar -Dict $booterQuirks -Name 'ProvideCustomSlide' -Type true
    Set-PlistScalar -Dict $booterQuirks -Name 'RebuildAppleMemoryMap' -Type true
    Set-PlistScalar -Dict $booterQuirks -Name 'ResizeAppleGpuBars' -Type integer -Value '-1'
    Set-PlistScalar -Dict $booterQuirks -Name 'SetupVirtualMap' -Type true
    Set-PlistScalar -Dict $booterQuirks -Name 'SyncRuntimePermissions' -Type true

    $miscBoot = Get-PlistDict -RootDict $rootDict -Path @('Misc','Boot')
    Set-PlistScalar -Dict $miscBoot -Name 'ShowPicker' -Type true
    Set-PlistScalar -Dict $miscBoot -Name 'Timeout' -Type integer -Value '5'
    Set-PlistScalar -Dict $miscBoot -Name 'PickerMode' -Type string -Value 'Builtin'
    Set-PlistScalar -Dict $miscBoot -Name 'HideAuxiliary' -Type false
    Set-PlistScalar -Dict $miscBoot -Name 'HibernateMode' -Type string -Value 'None'

    $miscDebug = Get-PlistDict -RootDict $rootDict -Path @('Misc','Debug')
    Set-PlistScalar -Dict $miscDebug -Name 'AppleDebug' -Type true
    Set-PlistScalar -Dict $miscDebug -Name 'ApplePanic' -Type true
    Set-PlistScalar -Dict $miscDebug -Name 'DisableWatchDog' -Type true
    Set-PlistScalar -Dict $miscDebug -Name 'Target' -Type integer -Value '67'
    Set-PlistScalar -Dict $miscDebug -Name 'DisplayLevel' -Type integer -Value '2147483650'

    $nvram = Get-PlistDict -RootDict $rootDict -Path @('NVRAM','Add','7C436110-AB2A-4BBB-A880-FE41995C9F82')
    Set-PlistScalar -Dict $nvram -Name 'boot-args' -Type string -Value '-v keepsyms=1 debug=0x100'

    $platformInfo = Get-PlistDict -RootDict $rootDict -Path @('PlatformInfo')
    $generic = Get-PlistDict -RootDict $rootDict -Path @('PlatformInfo','Generic')
    Set-PlistScalar -Dict $platformInfo -Name 'Automatic' -Type true
    Set-PlistScalar -Dict $generic -Name 'SpoofVendor' -Type true
    Set-PlistScalar -Dict $generic -Name 'ProcessorType' -Type integer -Value '0'
    Set-PlistScalar -Dict $generic -Name 'SystemMemoryStatus' -Type string -Value 'Auto'
    Set-PlistScalar -Dict $generic -Name 'MaxBIOSVersion' -Type false
    Set-PlistScalar -Dict $generic -Name 'SystemProductName' -Type string -Value $smbios
    Set-PlistScalar -Dict $generic -Name 'SystemSerialNumber' -Type string -Value $identifiers.SystemSerialNumber
    Set-PlistScalar -Dict $generic -Name 'MLB' -Type string -Value $identifiers.MLB
    Set-PlistScalar -Dict $generic -Name 'SystemUUID' -Type string -Value $identifiers.SystemUUID
    Set-PlistDataHex -Dict $generic -Name 'ROM' -Hex $identifiers.ROM

    $uefi = Get-PlistDict -RootDict $rootDict -Path @('UEFI')
    $driverCandidates = @()
    $openRuntime = Join-Path $efiOcRoot 'OpenRuntime.efi'
    $openHfs = Join-Path $efiOcRoot 'OpenHfsPlus.efi'
    if (Test-Path -LiteralPath $openRuntime) { $driverCandidates += 'OpenRuntime.efi' }
    if (Test-Path -LiteralPath $openHfs) { $driverCandidates += 'OpenHfsPlus.efi' }
    if ($driverCandidates.Count -eq 0) {
        $EXIT_CODE = $script:EXIT_TARGET_NOT_FOUND
        throw 'No OpenCore runtime filesystem drivers were found under EFI/OC.'
    }
    Set-DriverEntries -Uefi $uefi -Document $document -DriverNames $driverCandidates

    $acpi = Get-PlistDict -RootDict $rootDict -Path @('ACPI')
    Set-PlistArrayEmpty -Dict $acpi -Name 'Add'
    Set-PlistArrayEmpty -Dict $acpi -Name 'Delete'
    Set-PlistArrayEmpty -Dict $acpi -Name 'Patch'

    $deviceProperties = Get-PlistDict -RootDict $rootDict -Path @('DeviceProperties')
    Set-PlistArrayEmpty -Dict $deviceProperties -Name 'Add'
    Set-PlistArrayEmpty -Dict $deviceProperties -Name 'Delete'

    Write-DevintoshStepLog $step 'Machine-specific CPU, SMBIOS and boot policy applied.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Writing generated OpenCore configuration candidate'
    if ((Test-Path -LiteralPath $configPath) -and -not $Force) {
        $EXIT_CODE = $script:EXIT_VALIDATION_FAILURE
        throw "Generated config already exists: $configPath. Use -Force to replace it."
    }
    if ((Test-Path -LiteralPath $configPath) -and $Force) {
        $backupRoot = Join-Path $script:BackupRoot ("config-" + (Get-Timestamp -replace '[^0-9]',''))
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        Copy-Item -LiteralPath $configPath -Destination (Join-Path $backupRoot 'config.plist') -Force
        Add-DevintoshRollbackAction "Restore previous OpenCore config from $backupRoot" {
            if (Test-Path -LiteralPath (Join-Path $backupRoot 'config.plist')) {
                Copy-Item -LiteralPath (Join-Path $backupRoot 'config.plist') -Destination $configPath -Force
            }
        }
    }
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $writer = [System.Xml.XmlWriter]::Create($configPath, $settings)
    try { $document.Save($writer) } finally { $writer.Dispose() }
    if (-not (Test-Path -LiteralPath $configPath)) {
        $EXIT_CODE = $script:EXIT_ASSET_INTEGRITY_FAILURE
        throw 'Generated config.plist was not created.'
    }
    Add-DevintoshRollbackAction "Remove generated OpenCore config $configPath" {
        if (Test-Path -LiteralPath $configPath) { Remove-Item -LiteralPath $configPath -Force }
    }
    Write-DevintoshStepLog $step "OpenCore configuration candidate written to $configPath." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Validating generated configuration and recording unresolved requirements'
    try {
        $check = New-Object System.Xml.XmlDocument
        $check.Load($configPath)
        if ($null -eq $check.SelectSingleNode('/plist/dict')) { throw 'Generated config.plist has no plist root dictionary.' }
        $check.LoadXml($check.OuterXml)
    } catch {
        $EXIT_CODE = $script:EXIT_ASSET_INTEGRITY_FAILURE
        throw "Generated config.plist XML validation failed: $($_.Exception.Message)"
    }

    $kextRoot = Join-Path $efiOcRoot 'Kexts'
    $presentKexts = @(Get-ChildItem -LiteralPath $kextRoot -Filter '*.kext' -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    $requirements = @(
        'Lilu.kext is required for WhateverGreen, AppleALC and RestrictEvents plugins.',
        'VirtualSMC.kext is required for the SMC layer.',
        'WhateverGreen.kext is required for AMD GPU integration.',
        'A USB port map must be generated from the real hardware before enabling a USB kext.',
        'Audio layout-id must be resolved from the real codec and board wiring; it is intentionally not guessed.',
        'ACPI SSDTs must be generated from the host DSDT/firmware before enabling ACPI entries.',
        'SMBIOS identifiers in this candidate are synthetic and deterministic; they must not be reused across machines.'
    )
    $networkKextRequirement = $null
    $networkNames = @($profile.network.pnp | ForEach-Object { [string]$_.Name })
    $networkIds = @($profile.network.pnp | ForEach-Object { [string]$_.PnpDeviceId })
    if (($networkNames -join ' ') -match '(?i)I225|I226|Intel.*2\.5') {
        $networkKextRequirement = 'Evaluate AppleIGC.kext for the detected Intel 2.5GbE controller.'
    } elseif (($networkNames -join ' ') -match '(?i)Realtek.*8125|RTL8125') {
        $networkKextRequirement = 'Evaluate LucyRTL8125Ethernet.kext for the detected Realtek RTL8125 controller.'
    } elseif (($networkNames -join ' ') -match '(?i)Realtek.*8111|RTL8111') {
        $networkKextRequirement = 'Evaluate RealtekRTL8111.kext for the detected Realtek controller.'
    } elseif (($networkNames -join ' ') -match '(?i)I219|Intel.*Ethernet') {
        $networkKextRequirement = 'Evaluate IntelMausi.kext for the detected Intel Ethernet controller.'
    } else {
        $networkKextRequirement = 'Network controller was detected, but no safe automatic kext mapping exists in this phase.'
    }
    $requirements += $networkKextRequirement

    $report = [ordered]@{
        schemaVersion = 1
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        culture = 'en-US'
        status = 'ConfigurationCandidate'
        configPath = $configPath
        openCoreBinary = $openCoreBinary
        sourceSample = $sampleUri
        cpuPolicy = [ordered]@{
            detectedAlderLake = $isAlderLake
            cpuid1Data = '55060A00000000000000000000000000'
            cpuid1Mask = 'FFFFFFFF000000000000000000000000'
            minKernel = '19.0.0'
            provideCurrentCpuInfo = $true
        }
        gpuPolicy = [ordered]@{
            detected = $profile.gpu
            rx550Variant = 'Baffin'
            spoof = $false
        }
        smbios = [ordered]@{
            product = $smbios
            systemSerialNumber = $identifiers.SystemSerialNumber
            mlb = $identifiers.MLB
            systemUuid = $identifiers.SystemUUID
            rom = $identifiers.ROM
            identifiersAreSynthetic = $true
        }
        driversEnabled = $driverCandidates
        kextsPresent = $presentKexts
        requirements = $requirements
        configValidatedAsXml = $true
        readyForInstaller = $false
    }
    $report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    Write-DevintoshStepLog $step 'Generated config.plist is valid XML and unresolved runtime requirements were recorded.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Finalizing OpenCore configuration transaction'
    if (Test-Path -LiteralPath $samplePath) { Remove-Item -LiteralPath $samplePath -Force }
    Complete-DevintoshTransaction
    Write-DevintoshStepLog $step 'OpenCore configuration candidate finalized; installer integration is intentionally not enabled yet.' 'PASS'
    Complete-DevintoshProgress 'OpenCore hardware configuration complete'
    exit $script:EXIT_SUCCESS
}
catch {
    Write-DevintoshLog 'ERROR' $_.Exception.ToString()
    if ($EXIT_CODE -eq $script:EXIT_SUCCESS) { $EXIT_CODE = $script:EXIT_GENERAL_FAILURE }
    Write-DevintoshStepLog $step 'OpenCore configuration failed; starting automatic rollback.' 'FAIL'
    $rollbackOk = Invoke-DevintoshRollback
    if (-not $rollbackOk) { $EXIT_CODE = $script:EXIT_ROLLBACK_FAILURE }
    Write-DevintoshProgress $step $totalSteps 'OpenCore configuration failed'
    Write-Host ''
    Write-Host "[$($script:Red)FAIL$($script:Reset)] configure-opencore.ps1 exited with code $EXIT_CODE"
    exit $EXIT_CODE
}
