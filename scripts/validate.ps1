#requires -Version 5.1
<#
.SYNOPSIS
    Validates whether the physical Windows host is a candidate for bare-metal
    macOS Sequoia using the Qonfused/OSX-Hyper-V compatibility baseline.

.DESCRIPTION
    Validator only. It does not modify disks, firmware, boot configuration,
    drivers, or the Windows installation. RAW/uninitialized disks are included
    in the storage inventory so an unformatted target can be detected.

    The validator targets macOS Sequoia (15.x) and newer. Sequoia is the current
    supported baseline; Tahoe (26.x) remains excluded while the reference
    project marks it as in progress.

.NOTES
    Repository: https://github.com/weslleymurdock/devintosh
    Baseline:   https://github.com/Qonfused/OSX-Hyper-V
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ANSI colours. Unicode bar characters are generated from code points so this
# script remains safe when saved/executed by Windows PowerShell 5.1.
$script:Esc    = [char]27
$script:Reset  = "$Esc[0m"
$script:Bold   = "$Esc[1m"
$script:Dim    = "$Esc[2m"
$script:Indigo = "$Esc[38;2;99;102;241m"
$script:Blue   = "$Esc[38;2;59;130;246m"
$script:Cyan   = "$Esc[38;2;34;211;238m"
$script:Green  = "$Esc[38;2;74;222;128m"
$script:Yellow = "$Esc[38;2;250;204;21m"
$script:Red    = "$Esc[38;2;248;113;113m"
$script:White  = "$Esc[38;2;241;245;249m"
$script:Gray   = "$Esc[38;2;148;163;184m"

function Write-Title {
    Clear-Host
    Write-Host ''
    Write-Host "  $($script:Indigo)$($script:Bold)DEVINTOSH$($script:Reset) $($script:Gray)/ macOS Bare-Metal Validator$($script:Reset)"
    Write-Host "  $($script:Dim)Hardware compatibility assessment for macOS Sequoia+.$($script:Reset)"
    Write-Host ''
}

function Write-Section([string]$Title) {
    Write-Host ''
    Write-Host "  $($script:Blue)$($script:Bold)$Title$($script:Reset)"
    Write-Host "  $($script:Gray)$([string]([char]0x2500) * 72)$($script:Reset)"
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
    $width = 32
    $filled = [math]::Floor(($percent / 100) * $width)
    $filledChar = [char]0x2588
    $emptyChar = [char]0x2591

    $start = @(99, 102, 241)
    $end = @(59, 130, 246)
    $bar = [System.Text.StringBuilder]::new()

    for ($i = 0; $i -lt $width; $i++) {
        if ($i -lt $filled) {
            $ratio = if ($width -eq 1) { 1 } else { $i / ($width - 1) }
            $r = [math]::Round($start[0] + (($end[0] - $start[0]) * $ratio))
            $g = [math]::Round($start[1] + (($end[1] - $start[1]) * $ratio))
            $b = [math]::Round($start[2] + (($end[2] - $start[2]) * $ratio))
            [void]$bar.Append("$Esc[38;2;${r};${g};${b}m$filledChar$($script:Reset)")
        }
        else {
            [void]$bar.Append("$($script:Gray)$emptyChar$($script:Reset)")
        }
    }

    $plainActivity = if ($Activity.Length -gt 34) { $Activity.Substring(0, 34) } else { $Activity }
    $line = "  $($bar.ToString()) $($script:White)$percent%$($script:Reset)  $($script:Gray)$plainActivity$($script:Reset)"
    Write-Host -NoNewline "`r$line"
}

function Invoke-ProgressStep {
    param(
        [int]$Index,
        [int]$Total,
        [string]$Activity,
        [scriptblock]$Action
    )

    Write-ProgressGradient $Index $Total $Activity
    Start-Sleep -Milliseconds 70
    & $Action
    Write-ProgressGradient $Index $Total "$Activity - done"
    Start-Sleep -Milliseconds 70
}

function Get-SafeString {
    param($Value)
    if ($null -eq $Value) { return 'Unknown' }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return 'Unknown' }
    return $text.Trim()
}

function Get-CpuGeneration {
    param([string]$Name)

    if ($Name -match '(?i)(1[1-9])th Gen Intel') { return [int]$Matches[1] }
    if ($Name -match '(?i)i[3579]-(\d{4,5})') {
        $model = $Matches[1]
        if ($model.Length -ge 4) {
            if ($model.Substring(0, 2) -eq '10') { return 10 }
            return [int]$model.Substring(0, 2)
        }
    }
    return $null
}

function Test-SupportedGpu {
    param([string]$Name)

    $n = $Name.ToLowerInvariant()

    if ($n -match 'microsoft basic display|microsoft remote display|hyper-v') {
        return [pscustomobject]@{ Status = 'WARN'; Reason = 'Virtual/basic display adapter; not a bare-metal GPU.' }
    }
    if ($n -match 'nvidia|geforce|quadro|rtx|gtx') {
        return [pscustomobject]@{ Status = 'FAIL'; Reason = 'NVIDIA is not treated as graphics-compatible with modern macOS Sequoia.' }
    }
    if ($n -match 'amd|radeon|ati') {
        return [pscustomobject]@{ Status = 'PASS'; Reason = 'AMD/ATI detected; candidate for macOS graphics. Exact model still requires validation.' }
    }
    if ($n -match 'intel') {
        return [pscustomobject]@{ Status = 'WARN'; Reason = 'Intel GPU detected; exact generation/model and framebuffer support require validation.' }
    }
    return [pscustomobject]@{ Status = 'WARN'; Reason = 'GPU vendor/model could not be classified.' }
}

Write-Title

$hardware = [ordered]@{}
$results = [System.Collections.Generic.List[object]]::new()
$totalSteps = 10
$step = 0

Invoke-ProgressStep (++$step) $totalSteps 'Reading operating system' {
    $hardware.OS = Get-CimInstance Win32_OperatingSystem
}
Invoke-ProgressStep (++$step) $totalSteps 'Reading CPU and firmware' {
    $hardware.CPU = Get-CimInstance Win32_Processor
    $hardware.ComputerSystem = Get-CimInstance Win32_ComputerSystem
    $hardware.BIOS = Get-CimInstance Win32_BIOS
}
Invoke-ProgressStep (++$step) $totalSteps 'Reading motherboard and platform' {
    $hardware.BaseBoard = Get-CimInstance Win32_BaseBoard
    $hardware.Pnp = Get-CimInstance Win32_PnPEntity
}
Invoke-ProgressStep (++$step) $totalSteps 'Reading graphics adapters' {
    $hardware.GPU = Get-CimInstance Win32_VideoController
}
Invoke-ProgressStep (++$step) $totalSteps 'Reading physical storage' {
    if (Get-Command Get-Disk -ErrorAction SilentlyContinue) { $hardware.Disks = @(Get-Disk) }
    else { $hardware.Disks = @(Get-CimInstance Win32_DiskDrive) }
}
Invoke-ProgressStep (++$step) $totalSteps 'Reading network adapters' {
    $hardware.Network = @(Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.PhysicalAdapter -eq $true })
}
Invoke-ProgressStep (++$step) $totalSteps 'Reading audio devices' {
    $hardware.Audio = @($hardware.Pnp | Where-Object { $_.PNPClass -in @('MEDIA','AudioEndpoint') -or $_.Name -match '(?i)audio|sound|codec' })
}
Invoke-ProgressStep (++$step) $totalSteps 'Reading USB and input devices' {
    $hardware.USB = @($hardware.Pnp | Where-Object { $_.PNPClass -eq 'USB' })
}
Invoke-ProgressStep (++$step) $totalSteps 'Checking firmware security flags' {
    $hardware.CpuVirtualization = $hardware.CPU.VirtualizationFirmwareEnabled
    $hardware.HyperVRequirement = $hardware.CPU.VMMonitorModeExtensions
    $hardware.SecureBoot = try { Confirm-SecureBootUEFI -ErrorAction Stop } catch { $null }
}
Invoke-ProgressStep (++$step) $totalSteps 'Building compatibility assessment' { }

Write-Host "`r$(' ' * 110)`r"

Write-Section 'Target macOS compatibility'
Write-Result 'macOS Sequoia' 'PASS' '15.x - supported by current baseline.'
Write-Result 'macOS Tahoe' 'WARN' '26.x - reference project currently marks it in progress.'
Write-Result 'Validator scope' 'INFO' 'Sequoia 15.x or newer; Sequoia is the current eligible target.'

Write-Section 'CPU / firmware'
$cpu = @($hardware.CPU)[0]
$cpuName = Get-SafeString $cpu.Name
$generation = Get-CpuGeneration $cpuName
$cores = [int]$cpu.NumberOfCores
$threads = [int]$cpu.NumberOfLogicalProcessors

Write-Host "  CPU                 : $cpuName"
Write-Host "  Cores / threads     : $cores / $threads"
Write-Host "  Architecture        : $($cpu.AddressWidth)-bit"
Write-Host "  Virtualization      : $([string]$hardware.CpuVirtualization)"
Write-Host "  VM extensions       : $([string]$hardware.HyperVRequirement)"

if ($cpuName -match '(?i)AMD') {
    Write-Result 'CPU family' 'PASS' 'AMD detected; exact generation remains subject to configuration.'
}
elseif ($cpuName -match '(?i)Intel') {
    if ($generation -and $generation -ge 11) {
        Write-Result 'CPU family' 'WARN' "Intel $generation`th Gen+; Comet Lake spoofing is recommended by the reference baseline."
    }
    elseif ($generation -and $generation -ge 4) {
        Write-Result 'CPU family' 'PASS' "Intel $generation`th Gen; within the documented compatibility range."
    }
    else {
        Write-Result 'CPU family' 'WARN' 'Intel generation could not be reliably mapped.'
    }
}
else {
    Write-Result 'CPU family' 'FAIL' 'CPU vendor could not be identified as Intel or AMD.'
}

if ($cores -lt 4) { Write-Result 'CPU resources' 'WARN' "$cores physical cores; development workloads may be constrained." }
else { Write-Result 'CPU resources' 'PASS' "$cores physical cores available." }

Write-Section 'Memory'
$totalMemoryGB = [math]::Round($hardware.ComputerSystem.TotalPhysicalMemory / 1GB, 1)
Write-Host "  Physical memory     : $totalMemoryGB GB"
if ($totalMemoryGB -ge 16) { Write-Result 'RAM capacity' 'PASS' "$totalMemoryGB GB - good headroom for development." }
elseif ($totalMemoryGB -ge 8) { Write-Result 'RAM capacity' 'WARN' "$totalMemoryGB GB - basic installation floor, limited headroom." }
else { Write-Result 'RAM capacity' 'FAIL' "$totalMemoryGB GB - below the practical installation floor." }

Write-Section 'Graphics'
$physicalGpus = @($hardware.GPU | Where-Object { $_.Name -and $_.Name -notmatch '(?i)Microsoft Remote Display Adapter' })
if ($physicalGpus.Count -eq 0) {
    Write-Result 'GPU presence' 'FAIL' 'No physical GPU was detected.'
}
else {
    foreach ($gpu in $physicalGpus) {
        $gpuName = Get-SafeString $gpu.Name
        $gpuCheck = Test-SupportedGpu $gpuName
        Write-Host "  GPU                 : $gpuName"
        Write-Host "  Driver              : $(Get-SafeString $gpu.DriverVersion)"
        $vram = if ($gpu.AdapterRAM) { [math]::Round($gpu.AdapterRAM / 1GB, 1) } else { 'Unknown' }
        Write-Host "  VRAM (reported)     : $vram GB"
        Write-Result 'GPU compatibility' $gpuCheck.Status $gpuCheck.Reason
        $results.Add([pscustomobject]@{ Area = 'GPU'; Status = $gpuCheck.Status })
    }
}

Write-Section 'Physical storage'
if (@($hardware.Disks).Count -eq 0) {
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
        Write-Result 'Unformatted target disk' 'PASS' "$($rawDisks.Count) RAW/offline disk(s) visible; formatting is not required for detection."
    }
    else {
        Write-Result 'Unformatted target disk' 'INFO' 'No RAW/offline disk was specifically identified.'
    }
}

Write-Section 'Firmware / platform'
Write-Host "  Manufacturer        : $(Get-SafeString $hardware.ComputerSystem.Manufacturer)"
Write-Host "  Model               : $(Get-SafeString $hardware.ComputerSystem.Model)"
Write-Host "  Motherboard         : $(Get-SafeString $hardware.BaseBoard.Manufacturer) $(Get-SafeString $hardware.BaseBoard.Product)"
Write-Host "  BIOS                : $(Get-SafeString $hardware.BIOS.SMBIOSBIOSVersion)"
Write-Host "  BIOS release        : $(Get-SafeString $hardware.BIOS.ReleaseDate)"
if ($null -eq $hardware.SecureBoot) { Write-Result 'Secure Boot query' 'WARN' 'Unable to determine Secure Boot state.' }
else { Write-Result 'Secure Boot state' 'INFO' "Currently $($hardware.SecureBoot); preparation will determine boot policy." }

Write-Section 'Device inventory'
Write-Result 'Network adapters' 'INFO' "$( @($hardware.Network).Count ) physical adapter(s); chipset compatibility is validated later."
Write-Result 'Audio devices' 'INFO' "$( @($hardware.Audio).Count ) audio-related PnP device(s); codec configuration is handled later."
Write-Result 'USB devices' 'INFO' "$( @($hardware.USB).Count ) USB device(s); USB mapping is handled later."

Write-Section 'Final assessment'
$failures = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

if ($cpuName -notmatch '(?i)Intel|AMD') { $failures.Add('Unsupported/unknown CPU vendor.') }
if ($totalMemoryGB -lt 8) { $failures.Add('Less than 8 GB of physical RAM detected.') }

$gpuFailures = @($results | Where-Object { $_.Area -eq 'GPU' -and $_.Status -eq 'FAIL' })
$gpuPasses = @($results | Where-Object { $_.Area -eq 'GPU' -and $_.Status -eq 'PASS' })
if ($gpuFailures.Count -gt 0 -and $gpuPasses.Count -eq 0) {
    $failures.Add('No GPU classified as a viable modern macOS graphics candidate.')
}
elseif ($gpuPasses.Count -eq 0) {
    $warnings.Add('GPU compatibility is unresolved; exact graphics hardware must be validated before preparation.')
}

if (@($hardware.Disks).Count -eq 0) { $failures.Add('No physical target disk is visible to Windows.') }

if ($failures.Count -eq 0) {
    Write-Host ''
    Write-Host "  $($script:Green)$($script:Bold)RESULT: HOST IS A CANDIDATE FOR macOS SEQUOIA.$($script:Reset)"
    Write-Host ''
    Write-Host '  No hard blocker was found under the current compatibility baseline.'
    Write-Host '  When available, the next step is:'
    Write-Host "    $($script:White).\scripts\prepare.ps1$($script:Reset)"
}
else {
    Write-Host ''
    Write-Host "  $($script:Red)$($script:Bold)RESULT: HOST IS NOT CURRENTLY READY FOR macOS SEQUOIA.$($script:Reset)"
    foreach ($failure in $failures) { Write-Host "  $($script:Red)x$($script:Reset) $failure" }
    if ($warnings.Count -gt 0) {
        Write-Host ''
        Write-Host "  $($script:Yellow)Additional warnings:$($script:Reset)"
        foreach ($warning in $warnings) { Write-Host "  $($script:Yellow)!$($script:Reset) $warning" }
    }
    Write-Host ''
    Write-Host '  Resolve the hard blockers above and run this validator again.'
}

Write-Host ''
Write-Host "  $($script:Dim)Compatibility reference: Qonfused/OSX-Hyper-V (Sequoia supported; Tahoe in progress).$($script:Reset)"
Write-Host "  $($script:Dim)This script does not modify disks, firmware, boot configuration, or Windows.$($script:Reset)"
Write-Host ''
