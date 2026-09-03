#requires -Version 5.1
<#
.SYNOPSIS
    Prepares a Windows host for the Devintosh bare-metal macOS workflow.

.DESCRIPTION
    Performs non-destructive hardware, firmware, storage and workspace checks,
    captures a machine manifest, and establishes a rollback transaction for
    preparation changes. This phase does not erase, partition, format, or write
    an EFI bootloader to any disk.

.PARAMETER TargetDiskNumber
    Optional Windows physical disk number reserved for the future macOS install.
    The disk must not be the active Windows boot/system disk.

.PARAMETER Force
    Suppresses the interactive confirmation for a supplied target disk. It does
    not bypass safety checks and cannot authorize a Windows boot/system disk.

.EXIT CODES
    0 = Preparation completed successfully.
    1 = General preparation failure.
    2 = Hardware/host validation failure.
    3 = Administrator privileges are required.
    4 = Target disk was not found.
    5 = Automatic rollback failed.
    6 = Required external dependency is unavailable.
    7 = Generated manifest or asset integrity failure.
    8 = Hardware or configuration is unsupported for the selected macOS target.
#>

[CmdletBinding()]
param(
    [int]$TargetDiskNumber = -1,
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
. "$PSScriptRoot\lib\storage.ps1"

$EXIT_CODE = $script:EXIT_SUCCESS
$step = 0
$totalSteps = 9

Write-DevintoshTitle 'macOS Bare-Metal Preparation' 'Non-destructive preparation for macOS Sequoia.'
Initialize-DevintoshLogging 'prepare'
Start-DevintoshTransaction

try {
    $step++
    Write-DevintoshProgress $step $totalSteps 'Checking administrator privileges'
    if (-not (Test-IsAdministrator)) {
        Write-DevintoshStepLog $step 'Administrator privileges are required for preparation.' 'FAIL'
        $EXIT_CODE = $script:EXIT_INSUFFICIENT_PRIVILEGES
        throw 'Run prepare.ps1 from an elevated PowerShell session.'
    }
    Write-DevintoshStepLog $step 'Administrator privileges confirmed.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Loading host hardware inventory'
    $cpu = Get-DevintoshCpuIdentity
    $platform = Get-DevintoshPlatformIdentity
    $gpus = @(Get-DevintoshPhysicalGpus | ForEach-Object { Get-DevintoshGpuIdentity $_ })
    $pnp = @(Get-DevintoshPnpDevices)
    Write-DevintoshLog 'INFO' "Host: $($platform.Manufacturer) $($platform.Model); CPU: $($cpu.Name)."
    Write-DevintoshStepLog $step 'Hardware inventory loaded.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Validating macOS hardware baseline'
    $hasNvidia = @($gpus | Where-Object { $_.VendorId -eq '10DE' -or $_.Name -match '(?i)nvidia|geforce|quadro|rtx|gtx' }).Count -gt 0
    if ($hasNvidia) {
        Write-DevintoshStepLog $step 'NVIDIA graphics detected; Sequoia graphics compatibility is not supported by this baseline.' 'FAIL'
        $EXIT_CODE = $script:EXIT_UNSUPPORTED_CONFIGURATION
        throw 'Unsupported NVIDIA graphics configuration.'
    }
    $rx550 = @($gpus | ForEach-Object { Test-DevintoshRx550 $_ } | Where-Object { $_.IsRx550 })
    foreach ($gpu in $rx550) {
        $status = if ($gpu.Supported) { 'PASS' } else { 'WARN' }
        Write-DevintoshStepLog $step "RX 550 $($gpu.Variant): $($gpu.Reason)" $status
    }
    if ($gpus.Count -eq 0) {
        Write-DevintoshStepLog $step 'No physical GPU was detected.' 'FAIL'
        $EXIT_CODE = $script:EXIT_VALIDATION_FAILURE
        throw 'No physical GPU detected.'
    }
    if ($cpu.Cores -lt 4) {
        Write-DevintoshStepLog $step "Only $($cpu.Cores) CPU cores detected; development workload may be constrained." 'WARN'
    }
    Write-DevintoshStepLog $step 'Hardware baseline accepted for preparation; exact device profiles are resolved during OpenCore build.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Discovering physical storage'
    $disks = @(Get-DevintoshPhysicalDisks)
    if ($disks.Count -eq 0) {
        Write-DevintoshStepLog $step 'No physical disks detected.' 'FAIL'
        $EXIT_CODE = $script:EXIT_TARGET_NOT_FOUND
        throw 'No physical disks detected.'
    }
    Write-DevintoshStepLog $step "$($disks.Count) physical disk(s) detected." 'PASS'

    $target = $null
    if ($TargetDiskNumber -ge 0) {
        try { $target = Get-DevintoshDiskByNumber $TargetDiskNumber }
        catch {
            Write-DevintoshStepLog $step "Target disk #$TargetDiskNumber was not found." 'FAIL'
            $EXIT_CODE = $script:EXIT_TARGET_NOT_FOUND
            throw
        }
        $safety = Test-DevintoshDiskTarget $target
        if (-not $safety.Safe) {
            Write-DevintoshStepLog $step "Target disk #$TargetDiskNumber rejected: $($safety.Reason)" 'FAIL'
            $EXIT_CODE = $script:EXIT_VALIDATION_FAILURE
            throw $safety.Reason
        }
        if (-not $Force) {
            $description = if ($target.FriendlyName) { $target.FriendlyName } else { "Disk #$TargetDiskNumber" }
            $confirmation = Read-Host "Type TARGET-$TargetDiskNumber to reserve $description for future macOS installation"
            if ($confirmation -ne "TARGET-$TargetDiskNumber") {
                Write-DevintoshStepLog $step 'Target disk confirmation was not provided.' 'FAIL'
                $EXIT_CODE = $script:EXIT_VALIDATION_FAILURE
                throw 'Target disk confirmation cancelled.'
            }
        }
        $snapshotPath = New-DevintoshDiskSnapshot $target
        Add-DevintoshRollbackAction "Remove preparation snapshot $snapshotPath" { if (Test-Path -LiteralPath $snapshotPath) { Remove-Item -LiteralPath $snapshotPath -Force } }
        Write-DevintoshLog 'INFO' "Reserved target disk #$TargetDiskNumber; snapshot: $snapshotPath."
        Write-DevintoshStepLog $step "Target disk #$TargetDiskNumber accepted; no disk mutation performed." 'PASS'
    } else {
        Write-DevintoshStepLog $step 'No target disk selected. Preparation remains non-destructive; pass -TargetDiskNumber before installer build.' 'WARN'
    }

    $step++
    Write-DevintoshProgress $step $totalSteps 'Checking UEFI and Secure Boot state'
    $secureBoot = try { Confirm-SecureBootUEFI -ErrorAction Stop } catch { $null }
    $firmwareType = (Get-ItemPropertyValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'PEFirmwareType' -ErrorAction SilentlyContinue)
    if ($secureBoot -eq $true) {
        Write-DevintoshStepLog $step 'Secure Boot is enabled. Preparation records the state; it is not changed automatically in this phase.' 'WARN'
    } else {
        Write-DevintoshStepLog $step 'Secure Boot is disabled or unavailable.' 'INFO'
    }
    Write-DevintoshLog 'INFO' "FirmwareType registry value: $firmwareType; SecureBoot: $secureBoot."

    $step++
    Write-DevintoshProgress $step $totalSteps 'Checking required Windows capabilities'
    $requiredCommands = @('Get-Disk','Get-CimInstance','Confirm-SecureBootUEFI')
    foreach ($command in $requiredCommands) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            Write-DevintoshStepLog $step "Required command unavailable: $command." 'FAIL'
            $EXIT_CODE = $script:EXIT_DEPENDENCY_FAILURE
            throw "Required PowerShell command unavailable: $command"
        }
    }
    Write-DevintoshStepLog $step 'Required Windows PowerShell capabilities are available.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Writing hardware manifest'
    $manifest = [ordered]@{
        schemaVersion = 1
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        culture = 'en-US'
        targetMacOS = 'Sequoia-15'
        platform = $platform
        cpu = $cpu
        gpus = $gpus
        physicalDiskNumbers = @($disks | ForEach-Object { [int]$_.Number })
        targetDiskNumber = if ($target) { [int]$target.Number } else { $null }
        secureBoot = $secureBoot
        firmwareType = $firmwareType
        physicalNetworkAdapters = @(Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.PhysicalAdapter -eq $true } | ForEach-Object { [ordered]@{ Name = $_.Name; Manufacturer = $_.Manufacturer; PnpDeviceId = $_.PNPDeviceID } })
        audioDevices = @($pnp | Where-Object { $_.PNPClass -in @('MEDIA','AudioEndpoint') -or $_.Name -match '(?i)audio|sound|codec' } | ForEach-Object { [ordered]@{ Name = $_.Name; PnpDeviceId = $_.PNPDeviceID } })
        usbDevices = @($pnp | Where-Object { $_.PNPClass -eq 'USB' } | ForEach-Object { [ordered]@{ Name = $_.Name; PnpDeviceId = $_.PNPDeviceID } })
    }
    $manifestPath = Join-Path $script:BuildRoot 'hardware-manifest.json'
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Add-DevintoshRollbackAction "Remove generated hardware manifest $manifestPath" { if (Test-Path -LiteralPath $manifestPath) { Remove-Item -LiteralPath $manifestPath -Force } }
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw 'Hardware manifest was not created.' }
    Write-DevintoshStepLog $step "Hardware manifest written to $manifestPath." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Preparing build workspace'
    foreach ($directory in @(
        (Join-Path $script:RepoRoot 'assets'),
        (Join-Path $script:RepoRoot 'config'),
        (Join-Path $script:RepoRoot 'profiles'),
        (Join-Path $script:BuildRoot 'efi'),
        (Join-Path $script:BuildRoot 'recovery')
    )) {
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            Add-DevintoshRollbackAction "Remove workspace directory $directory" { if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force } }
        }
    }
    Write-DevintoshStepLog $step 'Build workspace is ready.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Finalizing preparation'
    Complete-DevintoshTransaction
    Write-DevintoshStepLog $step 'Preparation completed without modifying disks, firmware, Windows boot files, or UEFI settings.' 'PASS'
    Complete-DevintoshProgress 'Preparation complete'
    exit $script:EXIT_SUCCESS
}
catch {
    Write-DevintoshLog 'ERROR' $_.Exception.ToString()
    if ($EXIT_CODE -eq $script:EXIT_SUCCESS) { $EXIT_CODE = $script:EXIT_GENERAL_FAILURE }
    Write-DevintoshStepLog $step 'Preparation failed; starting automatic rollback.' 'FAIL'
    $rollbackOk = Invoke-DevintoshRollback
    if (-not $rollbackOk) { $EXIT_CODE = $script:EXIT_ROLLBACK_FAILURE }
    Write-DevintoshProgress $step $totalSteps 'Preparation failed'
    Write-Host ''
    Write-Host "[$($script:Red)FAIL$($script:Reset)] prepare.ps1 exited with code $EXIT_CODE"
    exit $EXIT_CODE
}
