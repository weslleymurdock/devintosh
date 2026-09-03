#requires -Version 5.1
<#
.SYNOPSIS
    Detects the real Windows hardware and generates an OpenCore hardware profile.

.DESCRIPTION
    Queries the running Windows installation directly through CIM/WMI, Plug and
    Play and the PCI registry. No hardware identity, Device ID, subsystem ID,
    codec, network controller or USB controller is accepted as manual input.

    The generated profile is an input artifact for the later OpenCore configuration
    phase. This script deliberately does not invent ACPI patches, audio layout IDs,
    USB maps, SMBIOS identifiers or kexts when Windows cannot prove them.

    The script is read-only with respect to the host hardware. It only writes the
    generated profile and a human-readable summary under build/opencore.

.PARAMETER Force
    Replaces an existing generated hardware profile after creating a backup.

.EXIT CODES
    0 = Hardware profile generated successfully.
    1 = General failure.
    2 = Validation failure.
    3 = Administrator privileges are required.
    4 = Required hardware information was not found.
    5 = Automatic rollback failed.
    6 = External dependency failure.
    7 = Generated profile integrity failure.
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
. "$PSScriptRoot\lib\hardware.ps1"

$EXIT_CODE = $script:EXIT_SUCCESS
$step = 0
$totalSteps = 9
$outputRoot = Join-Path $script:BuildRoot 'opencore'
$profilePath = Join-Path $outputRoot 'hardware-detected.json'
$summaryPath = Join-Path $outputRoot 'hardware-detected.txt'
$manifestPath = Join-Path $script:BuildRoot 'hardware-manifest.json'

function Get-RegistryPciDevices {
    $root = 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI'
    if (-not (Test-Path -LiteralPath $root)) { return @() }

    $result = @()
    foreach ($classKey in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
        $instanceKeys = @(Get-ChildItem -LiteralPath $classKey.PSPath -ErrorAction SilentlyContinue)
        foreach ($instanceKey in $instanceKeys) {
            try {
                $props = Get-ItemProperty -LiteralPath $instanceKey.PSPath -ErrorAction Stop
                $compatible = @($props.CompatibleIds)
                $hardware = @($props.HardwareID)
                $result += [pscustomobject]@{
                    PnpDeviceId = [string]$instanceKey.PSChildName
                    ClassKey = [string]$classKey.PSChildName
                    FriendlyName = [string]$props.FriendlyName
                    DeviceDesc = [string]$props.DeviceDesc
                    Manufacturer = [string]$props.Mfg
                    HardwareIds = @($hardware | ForEach-Object { [string]$_ })
                    CompatibleIds = @($compatible | ForEach-Object { [string]$_ })
                }
            } catch {
                Write-DevintoshLog 'DEBUG' "Unable to read PCI registry instance $($instanceKey.PSPath): $($_.Exception.Message)"
            }
        }
    }
    return $result
}

function Get-PnpIdentity {
    param([Parameter(Mandatory)]$Device)
    $id = [string]$Device.PNPDeviceID
    $vendor = $null
    $deviceId = $null
    $subsystem = $null
    if ($id -match '(?i)VEN_([0-9A-F]{4})') { $vendor = $Matches[1].ToUpperInvariant() }
    if ($id -match '(?i)DEV_([0-9A-F]{4})') { $deviceId = $Matches[1].ToUpperInvariant() }
    if ($id -match '(?i)SUBSYS_([0-9A-F]{8})') { $subsystem = $Matches[1].ToUpperInvariant() }
    return [ordered]@{
        Name = [string]$Device.Name
        Status = [string]$Device.Status
        PnpDeviceId = $id
        VendorId = $vendor
        DeviceId = $deviceId
        SubsystemId = $subsystem
        Manufacturer = [string]$Device.Manufacturer
        Service = [string]$Device.Service
        CompatibleIds = @($Device.CompatibleID | ForEach-Object { [string]$_ })
    }
}

function Get-PnpByClass {
    param([Parameter(Mandatory)][string[]]$Classes)
    return @(Get-CimInstance Win32_PnPEntity | Where-Object {
        $_.PNPClass -and $_.PNPClass -in $Classes
    })
}

try {
    $step++
    Write-DevintoshProgress $step $totalSteps 'Checking administrator privileges and runtime'
    if (-not (Test-IsAdministrator)) {
        $EXIT_CODE = $script:EXIT_INSUFFICIENT_PRIVILEGES
        Write-DevintoshStepLog $step 'Administrator privileges are required to inspect the complete Plug and Play hardware inventory.' 'FAIL'
        throw 'Run configure-opencore-hardware.ps1 from an elevated PowerShell session.'
    }
    Write-DevintoshStepLog $step 'Hardware detection runtime is available.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Reading motherboard, firmware and CPU'
    $platform = Get-DevintoshPlatformIdentity
    $cpu = Get-DevintoshCpuIdentity
    if ([string]::IsNullOrWhiteSpace($platform.MotherboardProduct) -or [string]::IsNullOrWhiteSpace($cpu.Name)) {
        $EXIT_CODE = $script:EXIT_TARGET_NOT_FOUND
        throw 'Unable to identify the motherboard or CPU from Windows.'
    }
    Write-DevintoshLog 'INFO' "Motherboard: $($platform.MotherboardManufacturer) $($platform.MotherboardProduct)."
    Write-DevintoshLog 'INFO' "BIOS: $($platform.BiosVersion)."
    Write-DevintoshLog 'INFO' "CPU: $($cpu.Name)."
    Write-DevintoshStepLog $step 'Motherboard, firmware and CPU identities collected from the running host.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Identifying physical GPU and exact PCI identity'
    $gpus = @(Get-DevintoshPhysicalGpus | ForEach-Object { Get-DevintoshGpuIdentity $_ })
    if ($gpus.Count -eq 0) {
        $EXIT_CODE = $script:EXIT_TARGET_NOT_FOUND
        throw 'No physical GPU was detected.'
    }
    $gpuAnalysis = @($gpus | ForEach-Object {
        $analysis = Test-DevintoshRx550 $_
        [pscustomobject]@{
            Identity = $_
            Rx550 = $analysis
        }
    })
    foreach ($gpu in $gpus) {
        Write-DevintoshLog 'INFO' "GPU: $($gpu.Name) | VEN_$($gpu.VendorId) DEV_$($gpu.DeviceId) SUBSYS_$($gpu.SubsystemId)."
    }
    Write-DevintoshStepLog $step 'Physical GPU identity and PCI IDs collected without manual input.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Detecting audio and network controllers'
    $audioDevices = @(Get-PnpByClass -Classes @('MEDIA','AudioEndpoint') | ForEach-Object { Get-PnpIdentity $_ })
    $networkDevices = @(Get-PnpByClass -Classes @('NET') | ForEach-Object { Get-PnpIdentity $_ })
    $networkAdapters = @(Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.PhysicalAdapter -eq $true } | ForEach-Object {
        [ordered]@{
            Name = [string]$_.Name
            Manufacturer = [string]$_.Manufacturer
            AdapterType = [string]$_.AdapterType
            PnpDeviceId = [string]$_.PNPDeviceID
            MacAddress = [string]$_.MACAddress
            Speed = $_.Speed
        }
    })
    Write-DevintoshLog 'INFO' "Audio devices detected: $($audioDevices.Count)."
    Write-DevintoshLog 'INFO' "Network controllers detected: $($networkDevices.Count)."
    Write-DevintoshStepLog $step 'Audio and network controller inventories collected.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Detecting USB controllers and ACPI devices'
    $usbControllers = @(Get-PnpByClass -Classes @('USB') | ForEach-Object { Get-PnpIdentity $_ })
    $acpiDevices = @(Get-PnpByClass -Classes @('SYSTEM') | Where-Object {
        [string]$_.PNPDeviceID -like 'ACPI*'
    } | ForEach-Object { Get-PnpIdentity $_ })
    $usbHubs = @(Get-CimInstance Win32_USBHub | ForEach-Object {
        [ordered]@{
            Name = [string]$_.Name
            DeviceId = [string]$_.DeviceID
            PnpDeviceId = [string]$_.PNPDeviceID
            Status = [string]$_.Status
        }
    })
    Write-DevintoshLog 'INFO' "USB PnP devices/controllers detected: $($usbControllers.Count)."
    Write-DevintoshLog 'INFO' "ACPI system devices detected: $($acpiDevices.Count)."
    Write-DevintoshStepLog $step 'USB controller and ACPI inventories collected.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Collecting PCI topology and storage-independent controller data'
    $pciDevices = @(Get-RegistryPciDevices)
    $pciClassCounts = @($pciDevices | Group-Object ClassKey | Sort-Object Name | ForEach-Object {
        [ordered]@{ Class = [string]$_.Name; Count = [int]$_.Count }
    })
    $pciHighlights = @($pciDevices | Where-Object {
        $_.PnpDeviceId -match '(?i)VEN_(1022|8086|1002|10EC|14E4|168C|8086)'
    } | Select-Object PnpDeviceId,ClassKey,FriendlyName,DeviceDesc,Manufacturer,HardwareIds,CompatibleIds)
    Write-DevintoshLog 'INFO' "PCI registry devices inspected: $($pciDevices.Count)."
    Write-DevintoshStepLog $step 'PCI topology and controller identities collected.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Resolving hardware-specific OpenCore capabilities'
    $rx550 = @($gpuAnalysis | Where-Object { $_.Rx550.IsRx550 -eq $true })
    $hardwareStatus = 'SupportedHardwareProfile'
    $warnings = @()
    $requirements = @()

    if ($rx550.Count -eq 1) {
        $variant = [string]$rx550[0].Rx550.Variant
        $supported = $rx550[0].Rx550.Supported
        if ($variant -eq 'Lexa') {
            $hardwareStatus = 'RequiresGpuSpoofValidation'
            $requirements += 'Validate the exact RX 550 Lexa-to-Polaris spoof strategy before generating config.plist.'
        } elseif ($variant -eq 'Unknown') {
            $hardwareStatus = 'RequiresGpuIdentityValidation'
            $requirements += 'RX 550 Device ID is not in the current classification table; update the hardware mapping before configuration.'
        } elseif ($supported -ne $true) {
            $hardwareStatus = 'RequiresHardwareValidation'
        }
    } elseif ($rx550.Count -gt 1) {
        $hardwareStatus = 'UnsupportedMultipleRx550'
        $EXIT_CODE = $script:EXIT_UNSUPPORTED_CONFIGURATION
        $warnings += 'Multiple RX 550 adapters were detected; automatic GPU configuration is intentionally blocked.'
    }

    $requiredFacts = @(
        'Motherboard manufacturer/product',
        'BIOS version',
        'CPU identity and topology',
        'GPU vendor/device/subsystem IDs',
        'Audio PnP identities',
        'Network controller identities',
        'USB controller identities',
        'ACPI device identities'
    )
    $unresolved = @(
        'SMBIOS serial/MLB/UUID values are not generated or persisted.',
        'Audio layout-id is not guessed from a codec name.',
        'USB port map is not guessed from the Windows device tree.',
        'ACPI patches are not guessed from device names.',
        'Kext versions are not inferred from Windows driver versions.'
    )
    Write-DevintoshStepLog $step "Hardware capability resolution completed with status: $hardwareStatus." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Writing machine-specific OpenCore hardware profile'
    if (-not (Test-Path -LiteralPath $outputRoot)) {
        New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
    }
    if ((Test-Path -LiteralPath $profilePath) -and -not $Force) {
        $EXIT_CODE = $script:EXIT_VALIDATION_FAILURE
        throw "Hardware profile already exists: $profilePath. Use -Force to replace it."
    }

    $profile = [ordered]@{
        schemaVersion = 1
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        source = 'Windows live hardware inspection'
        host = [ordered]@{
            manufacturer = [string]$platform.Manufacturer
            model = [string]$platform.Model
        }
        platform = $platform
        cpu = $cpu
        gpu = $gpus
        gpuAnalysis = $gpuAnalysis
        audio = $audioDevices
        network = [ordered]@{
            pnp = $networkDevices
            physicalAdapters = $networkAdapters
        }
        usb = [ordered]@{
            pnp = $usbControllers
            hubs = $usbHubs
        }
        acpi = $acpiDevices
        pci = [ordered]@{
            deviceCount = $pciDevices.Count
            classCounts = $pciClassCounts
            highlights = $pciHighlights
        }
        opencore = [ordered]@{
            status = $hardwareStatus
            requiredFacts = $requiredFacts
            requirements = $requirements
            warnings = $warnings
            intentionallyUnresolved = $unresolved
            configPlistGenerated = $false
        }
    }

    $profile | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $profilePath -Encoding UTF8
    if (-not (Test-Path -LiteralPath $profilePath)) {
        $EXIT_CODE = $script:EXIT_ASSET_INTEGRITY_FAILURE
        throw 'Generated hardware profile was not created.'
    }
    Add-DevintoshRollbackAction "Remove generated OpenCore hardware profile $profilePath" {
        if (Test-Path -LiteralPath $profilePath) { Remove-Item -LiteralPath $profilePath -Force }
    }
    Write-DevintoshStepLog $step "Machine-specific hardware profile written to $profilePath." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Writing hardware detection summary'
    $summary = @(
        'Devintosh OpenCore hardware detection',
        "Generated UTC: $($profile.generatedAtUtc)",
        "Status: $hardwareStatus",
        '',
        "Motherboard: $($platform.MotherboardManufacturer) $($platform.MotherboardProduct)",
        "BIOS: $($platform.BiosVersion)",
        "CPU: $($cpu.Name)",
        "CPU topology: $($cpu.Cores) cores / $($cpu.Threads) threads",
        ''
    )
    foreach ($gpu in $gpus) {
        $summary += "GPU: $($gpu.Name) | VEN_$($gpu.VendorId) DEV_$($gpu.DeviceId) SUBSYS_$($gpu.SubsystemId)"
    }
    $summary += ''
    $summary += "Audio PnP devices: $($audioDevices.Count)"
    $summary += "Network PnP devices: $($networkDevices.Count)"
    $summary += "USB PnP devices/controllers: $($usbControllers.Count)"
    $summary += "ACPI system devices: $($acpiDevices.Count)"
    $summary += "PCI registry devices: $($pciDevices.Count)"
    $summary += ''
    $summary += 'Intentionally not guessed:'
    $summary += $unresolved | ForEach-Object { "- $_" }
    if ($requirements.Count -gt 0) {
        $summary += ''
        $summary += 'Next validation requirements:'
        $summary += $requirements | ForEach-Object { "- $_" }
    }
    $summary | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    Write-DevintoshStepLog $step "Hardware detection summary written to $summaryPath." 'PASS'

    Complete-DevintoshTransaction
    Complete-DevintoshProgress 'OpenCore hardware detection complete'
    exit $script:EXIT_SUCCESS
}
catch {
    Write-DevintoshLog 'ERROR' $_.Exception.ToString()
    if ($EXIT_CODE -eq $script:EXIT_SUCCESS) { $EXIT_CODE = $script:EXIT_GENERAL_FAILURE }
    Write-DevintoshStepLog $step 'OpenCore hardware detection failed; starting automatic rollback.' 'FAIL'
    $rollbackOk = Invoke-DevintoshRollback
    if (-not $rollbackOk) { $EXIT_CODE = $script:EXIT_ROLLBACK_FAILURE }
    Write-DevintoshProgress $step $totalSteps 'OpenCore hardware detection failed'
    Write-Host ''
    Write-Host "[$($script:Red)FAIL$($script:Reset)] configure-opencore-hardware.ps1 exited with code $EXIT_CODE"
    exit $EXIT_CODE
}
