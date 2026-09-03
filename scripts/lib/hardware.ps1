#requires -Version 5.1
<#
.SYNOPSIS
    Shared hardware and PCI identification helpers.

.EXIT CODES
    0 = Success (library does not terminate the process).
    1 = General failure.
    2 = Validation failure.
    3 = Insufficient privileges.
    4 = Target device or resource not found.
    5 = Backup or rollback failure.
    6 = External dependency failure.
    7 = Asset integrity failure.
    8 = Unsupported hardware or configuration.
#>

Set-StrictMode -Version Latest

function Get-DevintoshPnpDevices {
    return @(Get-CimInstance Win32_PnPEntity)
}

function Get-DevintoshPhysicalGpus {
    return @(Get-CimInstance Win32_VideoController | Where-Object {
        $_.Name -and $_.Name -notmatch '(?i)Microsoft Remote Display Adapter|Microsoft Basic Display Adapter'
    })
}

function Get-DevintoshGpuIdentity {
    param([Parameter(Mandatory)]$Gpu)
    $pnpId = [string]$Gpu.PNPDeviceID
    $vendorId = $null
    $deviceId = $null
    $subsystemId = $null
    if ($pnpId -match '(?i)VEN_([0-9A-F]{4})') { $vendorId = $Matches[1].ToUpperInvariant() }
    if ($pnpId -match '(?i)DEV_([0-9A-F]{4})') { $deviceId = $Matches[1].ToUpperInvariant() }
    if ($pnpId -match '(?i)SUBSYS_([0-9A-F]{8})') { $subsystemId = $Matches[1].ToUpperInvariant() }
    return [pscustomobject]@{
        Name = [string]$Gpu.Name
        VendorId = $vendorId
        DeviceId = $deviceId
        SubsystemId = $subsystemId
        PnpDeviceId = $pnpId
        DriverVersion = [string]$Gpu.DriverVersion
        AdapterRam = $Gpu.AdapterRAM
    }
}

function Get-DevintoshCpuIdentity {
    $cpu = @(Get-CimInstance Win32_Processor)[0]
    return [pscustomobject]@{
        Name = [string]$cpu.Name
        Manufacturer = [string]$cpu.Manufacturer
        Cores = [int]$cpu.NumberOfCores
        Threads = [int]$cpu.NumberOfLogicalProcessors
        AddressWidth = [int]$cpu.AddressWidth
        VirtualizationFirmwareEnabled = [bool]$cpu.VirtualizationFirmwareEnabled
        VMMonitorModeExtensions = [bool]$cpu.VMMonitorModeExtensions
    }
}

function Get-DevintoshPlatformIdentity {
    $computer = @(Get-CimInstance Win32_ComputerSystem)[0]
    $bios = @(Get-CimInstance Win32_BIOS)[0]
    $board = @(Get-CimInstance Win32_BaseBoard)[0]
    return [pscustomobject]@{
        Manufacturer = [string]$computer.Manufacturer
        Model = [string]$computer.Model
        MotherboardManufacturer = [string]$board.Manufacturer
        MotherboardProduct = [string]$board.Product
        BiosVersion = [string]$bios.SMBIOSBIOSVersion
        BiosReleaseDate = [string]$bios.ReleaseDate
    }
}

function Test-DevintoshRx550 {
    param([Parameter(Mandatory)]$Gpu)
    $identity = if ($Gpu.PSObject.Properties.Name -contains 'VendorId') { $Gpu } else { Get-DevintoshGpuIdentity $Gpu }
    if ($identity.VendorId -ne '1002' -or [string]$identity.Name -notmatch '(?i)RX\s*550') {
        return [pscustomobject]@{ IsRx550 = $false; Variant = 'NotApplicable'; Supported = $null; Reason = 'GPU is not an RX 550.' }
    }
    # RX 550 can use Lexa or Baffin families. Exact PCI identity is retained
    # for the profile layer; no spoofing is inferred by this detection helper.
    $dev = $identity.DeviceId
    if ($dev -in @('67FF','67EF','67E0','67E1','67E3','67E8','67E9')) {
        return [pscustomobject]@{ IsRx550 = $true; Variant = 'Baffin'; Supported = $true; Reason = "Baffin-family device $dev detected; native Polaris configuration is the preferred path." }
    }
    if ($dev -in @('699F','6987','698F','6995','6997','6998')) {
        return [pscustomobject]@{ IsRx550 = $true; Variant = 'Lexa'; Supported = $false; Reason = "Lexa-family device $dev detected; spoofing to a supported Polaris identity may be required." }
    }
    return [pscustomobject]@{ IsRx550 = $true; Variant = 'Unknown'; Supported = $false; Reason = "RX 550 detected with unclassified device $dev; hardware-specific validation is required." }
}
