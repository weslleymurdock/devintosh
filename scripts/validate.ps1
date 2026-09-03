#requires -Version 5.1
<#
.SYNOPSIS
    Validates whether the current physical Windows host is a candidate for a
    bare-metal macOS installation using the compatibility baseline of Qonfused/OSX-Hyper-V.

.DESCRIPTION
    This script is intentionally a validator only. It does not modify disks,
    boot configuration, firmware settings, drivers, or the Windows installation.

    The current compatibility policy is deliberately limited to macOS Sequoia
    (15.x) and newer. Based on the OSX-Hyper-V project, Sequoia is supported,
    while Tahoe (26.x) is currently considered in progress and is therefore
    reported as not supported by this validator.

    Hardware is inspected through Windows CIM/WMI and SetupAPI/PnP information.
    A disk does not need to have a Windows filesystem to be inspected: RAW,
    uninitialized, and offline disks are reported from Get-Disk when available.

    IMPORTANT:
      - This project targets bare-metal installation, not Hyper-V.
      - Passing this validator does NOT prove that every device has a working
        macOS driver or that installation is guaranteed.
      - GPU compatibility is treated as a first-class requirement because the
        Hyper-V project explicitly lacks hardware graphics acceleration by default.
      - NVIDIA GPUs are not considered suitable for modern macOS Sequoia graphics
        in this validator. A supported AMD GPU is the expected route for acceleration.

.NOTES
    Repository: https://github.com/weslleymurdock/devintosh
    Compatibility baseline: https://github.com/Qonfused/OSX-Hyper-V
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# ANSI / console helpers
# -----------------------------------------------------------------------------
$script:Esc = [char]27
$script:Reset = "$Esc[0m"
$script:Bold = "$Esc[1m"
$script:Dim = "$Esc[2m"
$script:Indigo = "$Esc[38;2;99;102;241m"
$script:Blue = "$Esc[38;2;59;130;246m"
$script:Cyan = "$Esc[38;2;34;211;238m"
$script:Green = "$Esc[38;2;74;222;128m"
$script:Yellow = "$Esc[38;2;250;204;21m"
$script:Red = "$Esc[38;2;248;113;113m"
$script:White = "$Esc[38;2;241;245;249m"
$script:Gray = "$Esc[38;2;148;163;184m"

function Write-Title {
    Clear-Host
    Write-Host ""
    Write-Host "  $($script:Indigo)$($script:Bold)DEVINTOSH$($script:Reset) $($script:Gray)/ macOS Bare-Metal Validator$($script:Reset)"
    Write-Host "  $($script:Dim)Hardware compatibility assessment for macOS Sequoia+.$($script:Reset)"
    Write-Host ""
}

function Write-Section([string]$Title) {
    Write-Host ""
    Write-Host "  $($script:Blue)$($script:Bold)$Title$($script:Reset)"
    Write-Host "  $($script:Gray)$('─' * 72)$($script:Reset)"
}

function Write-Result {
    param(
        [string]$Name,
        [ValidateSet('PASS','WARN','FAIL','INFO')][string]$Status,
        [string]$Detail
    )

    $symbol = switch ($Status) {
        'PASS' { "$($script:Green)PASS$($script:Reset)" }
        'WARN' { "$($script:Yellow)WARN$($script:Reset)" }
        'FAIL' { "$($script:Red)FAIL$($script:Reset)" }
        default { "$($script:Cyan)INFO$($script:Reset)" }
    }

    Write-Host ("  [{0}] {1,-24} {2}" -f $symbol, $Name, $Detail)
}

function Write-ProgressGradient {
    param(
        [int]$Current,
        [int]$Total,
        [string]$Activity
    )

    $percent = if ($Total -le 0) { 100 } else { [math]::Min(100, [math]::Round(($Current / $Total) * 100)) }
    $width = 48
    $filled = [math]::Floor(($percent / 100) * $width)

    # Indigo -> blue RGB interpolation.
    $start = @(99, 102, 241)
    $end = @(59, 130, 246)
    $bar = [System.Text.StringBuilder]::new()

    for ($i = 0; $i -lt $width; $i++) {
        if ($i -lt $filled) {
            $ratio = if ($width -eq 1) { 1 } else { $i / ($width - 1) }
            $r = [math]::Round($start[0] + (($end[0] - $start[0]) * $ratio))
            $g = [math]::Round($start[1] + (($end[1] - $start[1]) * $ratio))
            $b = [math]::Round($start[2] + (($end[2] - $start[2]) * $ratio))
            [void]$bar.Append("$Esc[38;2;${r};${g};${b}m█$script:Reset")
        }
        else {
            [void]$bar.Append("$script:Gray░$script:Reset")
        }
    }

    Write-Host -NoNewline "`r  $($bar.ToString()) $($script:White)$percent%$($script:Reset)  $($script:Gray)$Activity$($script:Reset)"
}

function Invoke-ProgressStep {
    param(
        [int]$Index,
        [int]$Total,
        [string]$Activity,
        [scriptblock]$Action
    )

    Write-ProgressGradient -Current $Index -Total $Total -Activity $Activity
    Start-Sleep -Milliseconds 90
    & $Action
    Write-ProgressGradient -Current $Index -Total $Total -Activity "$Activity - done"
    Start-Sleep -Milliseconds 90
}

function Get-SafeString {
    param($Value)
    if ($null -eq $Value) { return 'Unknown' }
    $valueString = [string]$Value
    if ([string]::IsNullOrWhiteSpace($valueString)) { return 'Unknown' }
    return $valueString.Trim()
}

function Get-CpuGeneration {
    param([string]$Name)

    if ($Name -match '(?i)\b(1[1-9])th Gen Intel') {
        return [int]$Matches[1]
    }
    if ($Name -match '(?i)i[3579]-(\d{4,5})') {
        $model = $Matches[1]
        if ($model.Length -ge 4) {
            $prefix = $model.Substring(0, 2)
            if ($prefix -eq '10') { return 10 }
            return [int]$model.Substring(0, 2)
        }
    }
    return $null
}

function Test-SupportedGpu {
    param([string]$Name)

    $n = $Name.ToLowerInvariant()

    if ($n -match 'microsoft basic display|microsoft remote display|hyper-v') {
        return [pscustomobject]@{ Status = 'WARN'; Reason = 'Virtual/basic display adapter detected; this is not a bare-metal GPU.' }
    }

    if ($n -match 'nvidia|geforce|quadro|rtx|gtx') {
        return [pscustomobject]@{ Status = 'FAIL'; Reason = 'NVIDIA GPU is not treated as graphics-compatible with modern macOS Sequoia by this validator.' }
    }

    # AMD/ATI is intentionally accepted as a candidate, not a guarantee.
    if ($n -match 'amd|radeon|ati') {
        return [pscustomobject]@{ Status = 'PASS'; Reason = 'AMD/ATI GPU detected; candidate for macOS graphics compatibility. Exact GPU model still requires validation.' }
    }

    if ($n -match 'intel') {
        return [pscustomobject]@{ Status = 'WARN'; Reason = 'Intel GPU detected; exact generation/model and framebuffer support must be validated before installation.' }
    }

    return [pscustomobject]@{ Status = 'WARN'; Reason = 'GPU vendor/model could not be classified by the validator.' }
}

# -----------------------------------------------------------------------------
# Data collection
# -----------------------------------------------------------------------------
Write-Title

$hardware = [ordered]@{}
$results = [System.Collections.Generic.List[object]]::new()

$totalSteps = 10
$step = 0

Invoke-ProgressStep -Index (++$step) -Total $totalSteps -Activity 'Reading operating system' -Action {
    $hardware.OS = Get-CimInstance Win32_OperatingSystem
}

Invoke-ProgressStep -Index (++$step) -Total $totalSteps -Activity 'Reading CPU and firmware capabilities' -Action {
    $hardware.CPU = Get-CimInstance Win32_Processor
    $hardware.ComputerSystem = Get-CimInstance Win32_ComputerSystem
    $hardware.BIOS = Get-CimInstance Win32_BIOS
}

Invoke-ProgressStep -Index (++$step) -Total $totalSteps -Activity 'Reading motherboard and platform' -Action {
    $hardware.BaseBoard = Get-CimInstance Win32_BaseBoard
    $hardware.Pnp = Get-CimInstance Win32_PnPEntity
}

Invoke-ProgressStep -Index (++$step) -Total $totalSteps -Activity 'Reading graphics adapters' -Action {
    $hardware.GPU = Get-CimInstance Win32_VideoController
}

Invoke-ProgressStep -Index (++$step) -Total $totalSteps -Activity 'Reading physical storage devices' -Action {
    if (Get-Command Get-Disk -ErrorAction SilentlyContinue) {
        $hardware.Disks = @(Get-Disk)
    }
    else {
        $hardware.Disks = @(Get-CimInstance Win32_DiskDrive)
    }
}

Invoke-ProgressStep -Index (++$step) -Total $totalSteps -Activity 'Reading network adapters' -Action {
    $hardware.Network = Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.PhysicalAdapter -eq $true }
}

Invoke-ProgressStep -Index (++$step) -Total $totalSteps -Activity 'Reading audio and multimedia devices' -Action {
    $hardware.Audio = $hardware.Pnp | Where-Object {
        $_.PNPClass -in @('MEDIA','AudioEndpoint') -or $_.Name -match '(?i)audio|sound|codec'
    }
}

Invoke-ProgressStep -Index (++$step) -Total $totalSteps -Activity 'Reading USB and input devices' -Action {
    $hardware.USB = $hardware.Pnp | Where-Object { $_.PNPClass -eq 'USB' }
}

Invoke-ProgressStep -Index (++$step) -Total $totalSteps -Activity 'Checking virtualization and security flags' -Action {
    $hardware.CpuVirtualization = $hardware.CPU.VirtualizationFirmwareEnabled
    $hardware.HyperVRequirement = $hardware.CPU.VMMonitorModeExtensions
    $hardware.SecureBoot = try { Confirm-SecureBootUEFI -ErrorAction Stop } catch { $null }
}

Invoke-ProgressStep -Index (++$step) -Total $totalSteps -Activity 'Building compatibility assessment' -Action {
    # Intentionally empty: final checks are performed below.
}

Write-Host "`r$(' ' * 120)`r"

# -----------------------------------------------------------------------------
# OS / version policy
# -----------------------------------------------------------------------------
Write-Section 'Target macOS compatibility'

$targetVersions = @(
    [pscustomobject]@{ Name = 'macOS Sequoia'; Version = '15.x'; Status = 'Supported'; Eligible = $true; Notes = 'Supported by OSX-Hyper-V baseline.' },
    [pscustomobject]@{ Name = 'macOS Tahoe'; Version = '26.x'; Status = 'In Progress'; Eligible = $false; Notes = 'OSX-Hyper-V currently marks Tahoe as in progress.' }
)

foreach ($target in $targetVersions) {
    if ($target.Eligible) {
        Write-Result $target.Name 'PASS' "$($target.Version) - $($target.Status)"
    }
    else {
        Write-Result $target.Name 'WARN' "$($target.Version) - $($target.Status) - excluded by current policy"
    }
}

Write-Result 'Validator scope' 'INFO' 'Sequoia 15.x or newer only; current baseline makes Sequoia the eligible target.'

# -----------------------------------------------------------------------------
# CPU
# -----------------------------------------------------------------------------
Write-Section 'CPU / firmware'

$cpu = @($hardware.CPU)[0]
$cpuName = Get-SafeString $cpu.Name
$generation = Get-CpuGeneration $cpuName
$cores = [int]$cpu.NumberOfCores
$threads = [int]$cpu.NumberOfLogicalProcessors

Write-Host "  CPU                 : $cpuName"
Write-Host "  Cores / threads     : $cores / $threads"
Write-Host "  Architecture       : $($cpu.AddressWidth)-bit"
Write-Host "  Virtualization      : $([string]$hardware.CpuVirtualization)"
Write-Host "  VM extensions       : $([string]$hardware.HyperVRequirement)"

if ($cpuName -match '(?i)AMD') {
    Write-Result 'CPU family' 'PASS' 'AMD CPU detected; OSX-Hyper-V documents AMD kernel-patch support, subject to exact generation.'
}
elseif ($cpuName -match '(?i)Intel') {
    if ($generation -and $generation -ge 11) {
        Write-Result 'CPU family' 'WARN' "Intel $generation`th Gen+ detected; OSX-Hyper-V recommends Comet Lake spoofing for 11th Gen and newer."
    }
    elseif ($generation -and $generation -ge 4) {
        Write-Result 'CPU family' 'PASS' "Intel $generation`th Gen detected; within the documented Intel compatibility range."
    }
    else {
        Write-Result 'CPU family' 'WARN' 'Intel generation could not be reliably mapped; exact model requires manual review.'
    }
}
else {
    Write-Result 'CPU family' 'FAIL' 'CPU vendor could not be identified as Intel or AMD.'
}

if ($cores -lt 4) {
    Write-Result 'CPU resources' 'WARN' 'Fewer than 4 physical cores detected; installation may work but development workloads will be constrained.'
}
else {
    Write-Result 'CPU resources' 'PASS' "$cores physical cores available."
}

# -----------------------------------------------------------------------------
# Memory
# -----------------------------------------------------------------------------
Write-Section 'Memory'

$totalMemoryGB = [math]::Round($hardware.ComputerSystem.TotalPhysicalMemory / 1GB, 1)
Write-Host "  Physical memory     : $totalMemoryGB GB"

if ($totalMemoryGB -ge 16) {
    Write-Result 'RAM capacity' 'PASS' "$totalMemoryGB GB - sufficient headroom for Sequoia development workloads."
}
elseif ($totalMemoryGB -ge 8) {
    Write-Result 'RAM capacity' 'WARN' "$totalMemoryGB GB - meets a basic installation floor but leaves limited development headroom."
}
else {
    Write-Result 'RAM capacity' 'FAIL' "$totalMemoryGB GB - below the practical installation floor used by this project."
}

# -----------------------------------------------------------------------------
# GPU
# -----------------------------------------------------------------------------
Write-Section 'Graphics'

$physicalGpus = @($hardware.GPU | Where-Object {
    $_.Name -and $_.Name -notmatch '(?i)Microsoft Remote Display Adapter'
})

if ($physicalGpus.Count -eq 0) {
    Write-Result 'GPU presence' 'FAIL' 'No physical GPU was detected.'
}
else {
    foreach ($gpu in $physicalGpus) {
        $gpuName = Get-SafeString $gpu.Name
        $gpuCheck = Test-SupportedGpu $gpuName
        Write-Host "  GPU                 : $gpuName"
        Write-Host "  Driver              : $(Get-SafeString $gpu.DriverVersion)"
        Write-Host "  VRAM (reported)     : $(if ($gpu.AdapterRAM) { [math]::Round($gpu.AdapterRAM / 1GB, 1) } else { 'Unknown' }) GB"
        Write-Result 'GPU compatibility' $gpuCheck.Status $gpuCheck.Reason
        $results.Add([pscustomobject]@{ Area = 'GPU'; Status = $gpuCheck.Status; Detail = $gpuCheck.Reason })
    }
}

# -----------------------------------------------------------------------------
# Storage
# -----------------------------------------------------------------------------
Write-Section 'Physical storage'

if ($hardware.Disks.Count -eq 0) {
    Write-Result 'Storage enumeration' 'FAIL' 'No physical disks were returned by Windows.'
}
else {
    foreach ($disk in $hardware.Disks) {
        if ($disk.PSObject.Properties.Name -contains 'Number') {
            $sizeGB = [math]::Round($disk.Size / 1GB, 1)
            $partitionStyle = Get-SafeString $disk.PartitionStyle
            $bus = Get-SafeString $disk.BusType
            $health = Get-SafeString $disk.HealthStatus
            Write-Host "  Disk #$($disk.Number)           : $(Get-SafeString $disk.FriendlyName)"
            Write-Host "    Size / bus        : $sizeGB GB / $bus"
            Write-Host "    Partition / state : $partitionStyle / $(Get-SafeString $disk.OperationalStatus)"
            Write-Result "Disk #$($disk.Number)" 'INFO' "$sizeGB GB; partition=$partitionStyle; health=$health"
        }
        else {
            Write-Host "  Disk                 : $(Get-SafeString $disk.Model)"
            Write-Result 'Disk' 'INFO' "$(Get-SafeString $disk.Size) bytes"
        }
    }

    $rawDisks = @($hardware.Disks | Where-Object {
        ($_.PSObject.Properties.Name -contains 'PartitionStyle' -and $_.PartitionStyle -eq 'RAW') -or
        ($_.PSObject.Properties.Name -contains 'OperationalStatus' -and $_.OperationalStatus -contains 'Offline')
    })

    if ($rawDisks.Count -gt 0) {
        Write-Result 'Unformatted target disk' 'PASS' "$($rawDisks.Count) RAW/offline disk(s) visible to Windows; formatting is not required for detection."
    }
    else {
        Write-Result 'Unformatted target disk' 'INFO' 'No RAW/offline disk was specifically identified. A target disk may still be selected later by the preparation script.'
    }
}

# -----------------------------------------------------------------------------
# Firmware / motherboard
# -----------------------------------------------------------------------------
Write-Section 'Firmware / platform'

Write-Host "  Manufacturer        : $(Get-SafeString $hardware.ComputerSystem.Manufacturer)"
Write-Host "  Model               : $(Get-SafeString $hardware.ComputerSystem.Model)"
Write-Host "  Motherboard         : $(Get-SafeString $hardware.BaseBoard.Manufacturer) $(Get-SafeString $hardware.BaseBoard.Product)"
Write-Host "  BIOS                : $(Get-SafeString $hardware.BIOS.SMBIOSBIOSVersion)"
Write-Host "  BIOS release        : $(Get-SafeString $hardware.BIOS.ReleaseDate)"

if ($null -eq $hardware.SecureBoot) {
    Write-Result 'Secure Boot query' 'WARN' 'Unable to determine Secure Boot state from Windows.'
}
else {
    Write-Result 'Secure Boot state' 'INFO' "Currently $($hardware.SecureBoot). The preparation phase will determine the required boot policy."
}

# -----------------------------------------------------------------------------
# Network / audio / USB inventory
# -----------------------------------------------------------------------------
Write-Section 'Device inventory'

$networkCount = @($hardware.Network).Count
$audioCount = @($hardware.Audio).Count
$usbCount = @($hardware.USB).Count

Write-Result 'Network adapters' 'INFO' "$networkCount physical adapter(s) detected. Exact Ethernet/Wi-Fi chipset compatibility is required before finalizing OpenCore."
Write-Result 'Audio devices' 'INFO' "$audioCount audio-related PnP device(s) detected. Codec-specific configuration will be handled later."
Write-Result 'USB devices' 'INFO' "$usbCount USB device(s) detected. USB mapping is a later installation/post-install task."

# -----------------------------------------------------------------------------
# Final decision
# -----------------------------------------------------------------------------
Write-Section 'Final assessment'

$failures = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

# CPU is a hard gate only when the vendor is unknown.
if ($cpuName -notmatch '(?i)Intel|AMD') {
    $failures.Add('Unsupported/unknown CPU vendor.')
}

if ($totalMemoryGB -lt 8) {
    $failures.Add('Less than 8 GB of physical RAM detected.')
}

$gpuFailures = @($results | Where-Object { $_.Area -eq 'GPU' -and $_.Status -eq 'FAIL' })
$gpuPasses = @($results | Where-Object { $_.Area -eq 'GPU' -and $_.Status -eq 'PASS' })

if ($gpuFailures.Count -gt 0 -and $gpuPasses.Count -eq 0) {
    $failures.Add('No GPU classified as a viable modern macOS graphics candidate.')
}
elseif ($gpuPasses.Count -eq 0) {
    $warnings.Add('GPU compatibility is unresolved; exact graphics hardware must be validated before preparation.')
}

if (@($hardware.Disks).Count -eq 0) {
    $failures.Add('No physical target disk is visible to Windows.')
}

if ($failures.Count -eq 0) {
    Write-Host ""
    Write-Host "  $($script:Green)$($script:Bold)RESULT: HOST IS A CANDIDATE FOR macOS SEQUOIA.$($script:Reset)"
    Write-Host ""
    Write-Host "  The current validator found no hard blocker under the OSX-Hyper-V compatibility baseline."
    Write-Host "  The next step will be the preparation script, which will build the bootable media"
    Write-Host "  and configure the target disk."
    Write-Host ""
    Write-Host "  $($script:Cyan)$($script:Bold)NEXT STEP$($script:Reset)"
    Write-Host "  Run the preparation script when it is available:"
    Write-Host "    $($script:White).\scripts\prepare.ps1$($script:Reset)"
}
else {
    Write-Host ""
    Write-Host "  $($script:Red)$($script:Bold)RESULT: HOST IS NOT CURRENTLY READY FOR macOS SEQUOIA.$($script:Reset)"
    Write-Host ""
    foreach ($failure in $failures) {
        Write-Host "  $($script:Red)✗$($script:Reset) $failure"
    }

    if ($warnings.Count -gt 0) {
        Write-Host ""
        Write-Host "  $($script:Yellow)Additional warnings:$($script:Reset)"
        foreach ($warning in $warnings) {
            Write-Host "  $($script:Yellow)!$($script:Reset) $warning"
        }
    }

    Write-Host ""
    Write-Host "  Resolve the hard blockers above and run this validator again."
}

Write-Host ""
Write-Host "  $($script:Dim)Compatibility reference: Qonfused/OSX-Hyper-V (Sequoia supported; Tahoe in progress).$($script:Reset)"
Write-Host "  $($script:Dim)This script does not modify disks, firmware, boot configuration, or Windows.$($script:Reset)"
Write-Host ""
