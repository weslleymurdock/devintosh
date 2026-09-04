#requires -Version 5.1
<#
.SYNOPSIS
    Validates the physical disk EFI System Partition and UEFI fallback boot layout.
.DESCRIPTION
    Performs a read-only structural validation of a physical disk before the machine
    is rebooted into the generated Devintosh EFI. No partitioning, formatting, file
    writes, or boot-variable changes are performed.

    The validator checks GPT + EFI System Partition metadata, FAT32 filesystem,
    EFI/BOOT/BOOTX64.EFI, EFI/OC/OpenCore.efi, EFI/OC/config.plist, and the PE32+
    x86-64 format of the two EFI boot binaries.

    When -TargetDiskNumber is omitted, the script discovers a disk whose EFI
    partition contains the generated OpenCore fallback layout. This makes it usable
    as the final pipeline gate after prepare-boot-disk.ps1.

    When a disk number is supplied, that disk is validated explicitly. This mode is
    intended for inspecting an existing disk before a clean retry.
.PARAMETER TargetDiskNumber
    Optional physical disk number to validate. If omitted, the validator discovers
    the disk containing the Devintosh OpenCore EFI layout.
.PARAMETER Force
    Pipeline compatibility switch. This validator is strictly non-destructive and
    the switch has no behavioral effect.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][int]$TargetDiskNumber = -1,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\console.ps1"
. "$PSScriptRoot\lib\logging.ps1"
. "$PSScriptRoot\lib\progress.ps1"

$EXIT_CODE = $script:EXIT_SUCCESS
$step = 0
$totalSteps = 6
$EspTypeGuid = 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b'

function Get-PropertyValue {
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-PhysicalDisks {
    if (-not (Get-Command Get-Disk -ErrorAction SilentlyContinue)) {
        throw 'Get-Disk is required to validate the physical EFI partition.'
    }
    return @(Get-Disk -ErrorAction Stop | Where-Object { -not [bool](Get-PropertyValue $_ 'IsBoot') -or [int](Get-PropertyValue $_ 'Number') -ge 0 })
}

function Get-EfiPartitions {
    param([Parameter(Mandatory)][int]$DiskNumber)
    $partitions = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue)
    return @($partitions | Where-Object {
        $gptType = ([string](Get-PropertyValue $_ 'GptType')).ToLowerInvariant()
        $fs = ([string](Get-PropertyValue $_ 'Type')).ToLowerInvariant()
        $gptType -eq $EspTypeGuid -or $fs -match 'system|efi'
    })
}

function Get-FreeDriveLetter {
    foreach ($letter in @('S','R','T','U','V','W','X','Y','Z')) {
        if (-not (Get-PSDrive -Name $letter -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            return $letter
        }
    }
    throw 'No free drive letter is available for temporary EFI inspection.'
}

function Invoke-DiskPart {
    param([Parameter(Mandatory)][string[]]$Commands)
    $scriptPath = Join-Path $env:TEMP ("devintosh-efi-" + [Guid]::NewGuid().ToString('N') + '.txt')
    try {
        $Commands | Set-Content -LiteralPath $scriptPath -Encoding ASCII
        $output = & diskpart.exe /s $scriptPath 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "diskpart.exe failed with exit code $exitCode. $($output -join ' ')"
        }
        return @($output)
    }
    finally {
        if (Test-Path -LiteralPath $scriptPath) {
            Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Mount-EfiPartition {
    param([Parameter(Mandatory)]$Partition)
    $existingLetter = Get-PropertyValue $Partition 'DriveLetter'
    if ($null -ne $existingLetter -and -not [string]::IsNullOrWhiteSpace([string]$existingLetter)) {
        return [pscustomobject]@{ Root = ("{0}:\" -f [string]$existingLetter); Temporary = $false; Letter = [string]$existingLetter }
    }

    $diskNumber = [int](Get-PropertyValue $Partition 'DiskNumber')
    $partitionNumber = [int](Get-PropertyValue $Partition 'PartitionNumber')
    $letter = Get-FreeDriveLetter
    Invoke-DiskPart -Commands @(
        "select disk $diskNumber",
        "select partition $partitionNumber",
        "assign letter=$letter",
        'exit'
    ) | Out-Null
    Start-Sleep -Milliseconds 500

    $root = "${letter}:\"
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "EFI partition #$partitionNumber on disk #$diskNumber was assigned $letter but is not accessible."
    }
    return [pscustomobject]@{ Root = $root; Temporary = $true; Letter = $letter; DiskNumber = $diskNumber; PartitionNumber = $partitionNumber }
}

function Dismount-EfiPartition {
    param([Parameter(Mandatory)]$Mount)
    if (-not [bool]$Mount.Temporary) { return }
    try {
        Invoke-DiskPart -Commands @(
            "select disk $([int]$Mount.DiskNumber)",
            "select partition $([int]$Mount.PartitionNumber)",
            "remove letter=$([string]$Mount.Letter)",
            'exit'
        ) | Out-Null
    }
    catch {
        Write-DevintoshLog 'WARN' "Could not remove temporary EFI drive letter $($Mount.Letter): $($_.Exception.Message)"
    }
}

function Test-EfiPeX64 {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -lt 64) { return $false }
        if ($bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { return $false }
        $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
        if ($peOffset -lt 0 -or $peOffset + 6 -gt $bytes.Length) { return $false }
        if ($bytes[$peOffset] -ne 0x50 -or $bytes[$peOffset + 1] -ne 0x45 -or $bytes[$peOffset + 2] -ne 0x00 -or $bytes[$peOffset + 3] -ne 0x00) { return $false }
        $machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
        return $machine -eq 0x8664
    }
    catch {
        return $false
    }
}

function Get-DiskLabel {
    param([Parameter(Mandatory)]$Disk)
    $number = [int](Get-PropertyValue $Disk 'Number')
    $friendly = [string](Get-PropertyValue $Disk 'FriendlyName')
    if ([string]::IsNullOrWhiteSpace($friendly)) { $friendly = [string](Get-PropertyValue $Disk 'Model') }
    if ([string]::IsNullOrWhiteSpace($friendly)) { $friendly = 'Unknown device' }
    $size = if ($null -ne (Get-PropertyValue $Disk 'Size')) { '{0:N2} GiB' -f ([double](Get-PropertyValue $Disk 'Size') / 1GB) } else { 'size unknown' }
    return "Disk #$number | $size | $friendly"
}

function Test-EfiLayout {
    param([Parameter(Mandatory)]$Disk)
    $diskNumber = [int](Get-PropertyValue $Disk 'Number')
    $partitionStyle = ([string](Get-PropertyValue $Disk 'PartitionStyle')).ToUpperInvariant()
    if ($partitionStyle -ne 'GPT') {
        throw "Disk #$diskNumber is not GPT (partition style: $partitionStyle). UEFI ESP boot requires a GPT disk in this pipeline."
    }

    $espPartitions = @(Get-EfiPartitions -DiskNumber $diskNumber)
    if ($espPartitions.Count -ne 1) {
        throw "Disk #$diskNumber must contain exactly one EFI System Partition; detected $($espPartitions.Count)."
    }

    $esp = $espPartitions[0]
    $gptType = ([string](Get-PropertyValue $esp 'GptType')).ToLowerInvariant()
    if ($gptType -ne $EspTypeGuid) {
        throw "Disk #$diskNumber partition #$([int](Get-PropertyValue $esp 'PartitionNumber')) has an unexpected GPT type: $gptType."
    }

    $size = [double](Get-PropertyValue $esp 'Size')
    if ($size -lt (256MB)) {
        throw "Disk #$diskNumber EFI System Partition is only $([math]::Round($size / 1MB, 0)) MiB; at least 256 MiB is required by this validator."
    }

    $mount = $null
    try {
        $mount = Mount-EfiPartition -Partition $esp
        $root = $mount.Root
        $volume = Get-Volume -DriveLetter $mount.Letter -ErrorAction SilentlyContinue
        $filesystem = if ($null -ne $volume) { ([string](Get-PropertyValue $volume 'FileSystem')).ToUpperInvariant() } else { '' }
        if ($filesystem -ne 'FAT32') {
            throw "Disk #$diskNumber EFI System Partition is not FAT32 (filesystem: '$filesystem')."
        }

        $paths = [ordered]@{
            'EFI root' = Join-Path $root 'EFI'
            'UEFI fallback loader' = Join-Path $root 'EFI\BOOT\BOOTX64.EFI'
            'OpenCore loader' = Join-Path $root 'EFI\OC\OpenCore.efi'
            'OpenCore configuration' = Join-Path $root 'EFI\OC\config.plist'
        }
        foreach ($name in $paths.Keys) {
            if (-not (Test-Path -LiteralPath $paths[$name] -PathType $(if ($name -eq 'EFI root') { 'Container' } else { 'Leaf' }))) {
                throw "Required EFI layout entry is missing: $name -> $($paths[$name])"
            }
        }

        if (-not (Test-EfiPeX64 -Path $paths['UEFI fallback loader'])) {
            throw 'EFI/BOOT/BOOTX64.EFI is not a valid x86-64 PE EFI binary.'
        }
        if (-not (Test-EfiPeX64 -Path $paths['OpenCore loader'])) {
            throw 'EFI/OC/OpenCore.efi is not a valid x86-64 PE EFI binary.'
        }

        $ocRoot = Join-Path $root 'EFI\OC'
        $inventory = @(Get-ChildItem -LiteralPath $ocRoot -File -Recurse -ErrorAction Stop | ForEach-Object { $_.FullName.Substring($root.Length).TrimStart('\') })
        if ($inventory.Count -eq 0) {
            throw 'EFI/OC exists but contains no files.'
        }

        return [pscustomobject]@{
            DiskNumber = $diskNumber
            PartitionNumber = [int](Get-PropertyValue $esp 'PartitionNumber')
            EfiSizeMiB = [math]::Round($size / 1MB, 0)
            FileSystem = $filesystem
            Root = $root
            Inventory = $inventory
        }
    }
    finally {
        if ($null -ne $mount) { Dismount-EfiPartition -Mount $mount }
    }
}

function Find-GeneratedEfiDisk {
    $matches = @()
    foreach ($disk in @(Get-PhysicalDisks)) {
        $number = [int](Get-PropertyValue $disk 'Number')
        try {
            $result = Test-EfiLayout -Disk $disk
            if ($null -ne $result) { $matches += [pscustomobject]@{ Disk = $disk; Result = $result } }
        }
        catch {
            Write-DevintoshLog 'INFO' "Disk #$number does not match the complete Devintosh EFI layout: $($_.Exception.Message)"
        }
    }
    if ($matches.Count -eq 1) { return $matches[0] }
    if ($matches.Count -gt 1) { throw "Multiple disks contain a complete Devintosh EFI layout ($($matches.Result.DiskNumber -join ', ')); specify -TargetDiskNumber explicitly." }
    throw 'No physical disk contains a complete Devintosh EFI layout. Specify -TargetDiskNumber to inspect a particular disk and obtain the exact structural failure.'
}

try {
    $step++
    Write-DevintoshProgress $step $totalSteps 'Checking administrator privileges for EFI inspection'
    if (-not (Test-IsAdministrator)) {
        $EXIT_CODE = $script:EXIT_INSUFFICIENT_PRIVILEGES
        throw 'Run verify-efi-partition.ps1 from an elevated PowerShell session.'
    }
    Write-DevintoshStepLog $step 'Administrator privileges passed; no disk mutation will be performed.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Selecting the physical disk to inspect'
    if ($TargetDiskNumber -ge 0) {
        $disk = @(Get-PhysicalDisks | Where-Object { [int](Get-PropertyValue $_ 'Number') -eq $TargetDiskNumber } | Select-Object -First 1)[0]
        if ($null -eq $disk) {
            $EXIT_CODE = $script:EXIT_TARGET_NOT_FOUND
            throw "Physical disk #$TargetDiskNumber was not found."
        }
        Write-DevintoshStepLog $step "Explicit target selected: $(Get-DiskLabel -Disk $disk)." 'PASS'
    }
    else {
        $match = Find-GeneratedEfiDisk
        $disk = $match.Disk
        Write-DevintoshStepLog $step "Auto-detected generated Devintosh EFI on disk #$([int](Get-PropertyValue $disk 'Number'))." 'PASS'
    }

    $step++
    Write-DevintoshProgress $step $totalSteps 'Validating GPT and EFI System Partition metadata'
    $espPartitions = @(Get-EfiPartitions -DiskNumber ([int](Get-PropertyValue $disk 'Number')))
    Write-DevintoshStepLog $step "Detected $($espPartitions.Count) EFI System Partition candidate(s)." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Validating FAT32 EFI filesystem and UEFI fallback path'
    $result = Test-EfiLayout -Disk $disk
    Write-DevintoshStepLog $step "ESP partition #$($result.PartitionNumber): $($result.FileSystem), $($result.EfiSizeMiB) MiB; EFI/BOOT/BOOTX64.EFI is present." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Validating OpenCore EFI root structure'
    Write-DevintoshStepLog $step 'EFI/OC/OpenCore.efi and EFI/OC/config.plist are present and both EFI binaries are x86-64 PE images.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Finalizing EFI partition boot-layout gate'
    Write-DevintoshStepLog $step "Disk #$($result.DiskNumber) has the required UEFI fallback layout. No partition or file changes were made." 'PASS'
    Complete-DevintoshProgress 'EFI partition validation complete'
    exit $script:EXIT_SUCCESS
}
catch {
    Write-DevintoshLog 'ERROR' "EFI partition validation failed: $($_.Exception.Message)"
    if ($EXIT_CODE -eq $script:EXIT_SUCCESS) { $EXIT_CODE = $script:EXIT_VALIDATION_FAILURE }
    Write-DevintoshProgress $step $totalSteps 'EFI partition validation failed'
    exit $EXIT_CODE
}
