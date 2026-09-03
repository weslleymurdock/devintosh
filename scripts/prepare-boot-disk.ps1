#requires -Version 5.1
<#
.SYNOPSIS
    Interactively prepares a physical disk for a Devintosh UEFI boot test.
.DESCRIPTION
    Creates a GPT disk with a FAT32 EFI System Partition and a FAT32 Recovery
    staging partition. The remaining disk space is intentionally left unallocated
    so macOS Disk Utility can create the final APFS container during setup.

    Unlike earlier versions, this script accepts both RAW/uninitialized disks and
    existing non-system disks (for example NTFS data disks). Existing partitions are
    intentionally destroyed only after the user selects the disk from an interactive
    menu and confirms the exact destructive operation token.

    Windows boot/system disks are rejected. There is no reliable rollback after the
    diskpart CLEAN command starts, so selection and confirmation are deliberately
    performed immediately before the irreversible storage operation.

    OpenCore is installed as the primary UEFI fallback loader at EFI/BOOT/BOOTX64.EFI.
    Clover is installed under EFI/CLOVER as a fallback selector and explicitly chains
    to EFI/OC/OpenCore.efi. Windows BCD and the Windows system disk are untouched.

.PARAMETER TargetDiskNumber
    Optional physical Windows disk number. If omitted, an interactive safe disk menu
    is displayed. Even when supplied, the destructive confirmation is still required.
.PARAMETER Force
    Explicitly acknowledges that the selected disk will be repartitioned. This does
    not bypass the final interactive destructive confirmation.
.PARAMETER EfiSizeMB
    EFI System Partition size. Default 512 MiB.
.PARAMETER RecoverySizeMB
    FAT32 Recovery staging partition size. Default 2048 MiB.

.EXIT CODES
    0 = Boot disk preparation completed successfully.
    1 = General failure.
    2 = Validation failure.
    3 = Administrator privileges are required.
    4 = Target disk or required resource was not found.
    5 = Automatic rollback failed.
    6 = External dependency failure.
    7 = Asset integrity failure.
    8 = Unsupported configuration.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][int]$TargetDiskNumber = -1,
    [switch]$Force,
    [ValidateRange(256, 4096)][int]$EfiSizeMB = 512,
    [ValidateRange(1024, 4096)][int]$RecoverySizeMB = 2048
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\console.ps1"
. "$PSScriptRoot\lib\logging.ps1"
. "$PSScriptRoot\lib\progress.ps1"
. "$PSScriptRoot\lib\rollback.ps1"
. "$PSScriptRoot\lib\storage.ps1"
. "$PSScriptRoot\lib\menu-select.ps1"

$EXIT_CODE = $script:EXIT_SUCCESS
$step = 0
$totalSteps = 10
$disk = $null
$efiLetter = $null
$recoveryLetter = $null
$workspace = Join-Path $script:BuildRoot 'boot-disk'
$cloverWorkspace = Join-Path $workspace 'clover'
$cloverZip = Join-Path $workspace 'CloverV2-5175.zip'
$cloverConfig = Join-Path $workspace 'Clover-config.plist'
$cloverVersionPath = Join-Path $script:RepoRoot 'config\versions\clover.json'
$recoverySource = Join-Path $script:BuildRoot 'recovery'
$efiSource = Join-Path $script:BuildRoot 'efi\EFI'

function Get-PropertyValue {
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-FreeDriveLetter {
    param([string[]]$Exclude = @())
    foreach ($letter in @('S','R','T','U','V','W','X','Y','Z')) {
        if ($Exclude -contains $letter) { continue }
        if (-not (Get-PSDrive -Name $letter -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            return $letter
        }
    }
    throw 'No free drive letter is available for temporary disk access.'
}

function Invoke-DiskPart {
    param([Parameter(Mandatory)][string[]]$Commands)
    $scriptPath = Join-Path $env:TEMP ("devintosh-diskpart-" + [Guid]::NewGuid().ToString('N') + '.txt')
    try {
        $Commands | Set-Content -LiteralPath $scriptPath -Encoding ASCII
        $output = & diskpart.exe /s $scriptPath 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) { throw "diskpart.exe failed with exit code $exitCode. $($output -join ' ')" }
        return @($output)
    }
    finally {
        if (Test-Path -LiteralPath $scriptPath) { Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue }
    }
}

function Get-PartitionForDisk {
    param([int]$Number)
    if (Get-Command Get-Partition -ErrorAction SilentlyContinue) {
        return @(Get-Partition -DiskNumber $Number -ErrorAction SilentlyContinue)
    }
    return @()
}

function Get-DiskMenuLabel {
    param([Parameter(Mandatory)]$Disk)
    $number = [int](Get-PropertyValue $Disk 'Number')
    $friendly = [string](Get-PropertyValue $Disk 'FriendlyName')
    if ([string]::IsNullOrWhiteSpace($friendly)) { $friendly = [string](Get-PropertyValue $Disk 'Model') }
    if ([string]::IsNullOrWhiteSpace($friendly)) { $friendly = 'Unknown device' }

    $sizeValue = Get-PropertyValue $Disk 'Size'
    $size = if ($null -ne $sizeValue) { '{0:N2} GiB' -f ([double]$sizeValue / 1GB) } else { 'size unknown' }
    $style = [string](Get-PropertyValue $Disk 'PartitionStyle')
    if ([string]::IsNullOrWhiteSpace($style)) { $style = 'RAW/unknown' }
    $parts = @(Get-PartitionForDisk $number)
    $partitionText = if ($parts.Count -eq 0) { 'no partitions' } else { "$($parts.Count) partition(s)" }

    return "Disk #$number | $size | $style | $partitionText | $friendly"
}

function Select-TargetDisk {
    param([int]$RequestedNumber)

    $disks = @(Get-DevintoshPhysicalDisks)
    if ($disks.Count -eq 0) {
        $script:EXIT_CODE = $script:EXIT_TARGET_NOT_FOUND
        throw 'No physical disks were discovered.'
    }

    $safeCandidates = @()
    foreach ($candidate in $disks) {
        try {
            $safety = Test-DevintoshDiskTarget -Disk $candidate
            if ($safety.Safe) { $safeCandidates += $candidate }
        }
        catch {
            Write-DevintoshLog 'WARN' "Disk #$((Get-PropertyValue $candidate 'Number')) was excluded from the selection menu: $($_.Exception.Message)"
        }
    }

    if ($RequestedNumber -ge 0) {
        $requested = $disks | Where-Object { [int](Get-PropertyValue $_ 'Number') -eq $RequestedNumber } | Select-Object -First 1
        if ($null -eq $requested) {
            $script:EXIT_CODE = $script:EXIT_TARGET_NOT_FOUND
            throw "Physical disk #$RequestedNumber was not found."
        }
        $safety = Test-DevintoshDiskTarget -Disk $requested
        if (-not $safety.Safe) {
            $script:EXIT_CODE = $script:EXIT_VALIDATION_FAILURE
            throw "Disk #$RequestedNumber cannot be selected: $($safety.Reason)"
        }
        return $requested
    }

    if ($safeCandidates.Count -eq 0) {
        $script:EXIT_CODE = $script:EXIT_VALIDATION_FAILURE
        throw 'No disk is eligible for destructive preparation. Windows boot/system disks are intentionally excluded.'
    }

    $selected = Select-DevintoshMenuItem -Items $safeCandidates -Title 'Devintosh boot disk selection' -Prompt 'Select the disk number shown in the menu, or Q to cancel' -AllowCancel -LabelScript {
        param($item)
        Get-DiskMenuLabel -Disk $item
    }

    if ($null -eq $selected) {
        $script:EXIT_CODE = $script:EXIT_VALIDATION_FAILURE
        throw 'Disk selection cancelled by the user.'
    }
    return $selected
}

function Download-AndVerifyClover {
    $version = Get-Content -LiteralPath $cloverVersionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $assetUrl = [string]$version.assetUrl
    $expected = ([string]$version.assetSha256).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($assetUrl) -or [string]::IsNullOrWhiteSpace($expected)) {
        $script:EXIT_CODE = $script:EXIT_ASSET_INTEGRITY_FAILURE
        throw 'Clover version manifest is missing assetUrl or assetSha256.'
    }
    $parent = Split-Path -Parent $cloverZip
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Invoke-WebRequest -Uri $assetUrl -UseBasicParsing -OutFile $cloverZip
    $actual = (Get-FileHash -LiteralPath $cloverZip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        $script:EXIT_CODE = $script:EXIT_ASSET_INTEGRITY_FAILURE
        throw "Clover SHA-256 mismatch. Expected $expected; got $actual."
    }
    return $version
}

function Find-CloverEfiRoot {
    $extractedRoot = Join-Path $cloverWorkspace 'extracted'
    $matches = @(
        Get-ChildItem -LiteralPath $extractedRoot -Directory -Recurse -ErrorAction Stop |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'CLOVER') -PathType Container }
    )
    if ($matches.Count -gt 0) { return $matches[0].FullName }
    $direct = Join-Path $extractedRoot 'EFI'
    if (Test-Path -LiteralPath (Join-Path $direct 'CLOVER') -PathType Container) { return $direct }
    throw 'Clover archive does not contain an EFI/CLOVER directory.'
}

function Write-CloverConfig {
@'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Boot</key>
    <dict>
        <key>Timeout</key><integer>-1</integer>
        <key>Debug</key><true/>
    </dict>
    <key>GUI</key>
    <dict>
        <key>Scan</key>
        <dict>
            <key>Entries</key><true/>
            <key>Tool</key><true/>
        </dict>
        <key>Custom</key>
        <dict>
            <key>Entries</key>
            <array>
                <dict>
                    <key>Disabled</key><false/>
                    <key>FullTitle</key><string>OpenCore</string>
                    <key>Path</key><string>\EFI\OC\OpenCore.efi</string>
                    <key>Type</key><string>Other</string>
                    <key>Volume</key><string>EFI</string>
                    <key>VolumeType</key><string>Internal</string>
                </dict>
            </array>
        </dict>
    </dict>
    <key>SMBIOS</key><dict/>
    <key>SystemParameters</key>
    <dict><key>InjectKexts</key><false/></dict>
</dict>
</plist>
'@ | Set-Content -LiteralPath $cloverConfig -Encoding UTF8
}

function Remove-DriveLetterSafe {
    param([AllowNull()][string]$Letter)
    if ([string]::IsNullOrWhiteSpace($Letter)) { return }
    try { & mountvol.exe "${Letter}:" /D 2>&1 | Out-Null } catch { }
}

try {
    Start-DevintoshTransaction

    $step++; Write-DevintoshProgress $step $totalSteps 'Checking administrator privileges and destructive-stage prerequisites'
    if (-not (Test-IsAdministrator)) { $EXIT_CODE=$script:EXIT_INSUFFICIENT_PRIVILEGES; throw 'Run prepare-boot-disk.ps1 from an elevated PowerShell session.' }
    if (-not $Force) {
        Write-DevintoshLog 'WARN' 'Interactive mode is enabled. -Force was not supplied; the final typed destructive confirmation is still mandatory.'
    }
    Write-DevintoshStepLog $step 'Administrator privileges and safety prerequisites passed.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Selecting a physical target disk'
    $disk = Select-TargetDisk -RequestedNumber $TargetDiskNumber
    $diskNumber = [int](Get-PropertyValue $disk 'Number')
    $safety = Test-DevintoshDiskTarget -Disk $disk
    if (-not $safety.Safe) { $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw $safety.Reason }
    $snapshot = New-DevintoshDiskSnapshot -Disk $disk
    Write-DevintoshLog 'INFO' "Target disk: #$diskNumber; $(Get-DiskMenuLabel -Disk $disk)"
    Write-DevintoshLog 'INFO' "Disk snapshot: $snapshot"
    Write-DevintoshStepLog $step "Disk #$diskNumber selected and passed boot/system-disk protection." 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Reconfirming the destructive target'
    $partitionList = @(Get-PartitionForDisk $diskNumber)
    $partitionSummary = if ($partitionList.Count -eq 0) { 'no existing partitions' } else { "$($partitionList.Count) existing partition(s) WILL BE DESTROYED" }
    $warning = @(
        "Disk #$diskNumber will be CLEANED and converted to GPT.",
        $partitionSummary,
        'All data currently stored on this disk will be lost.',
        'There is no reliable rollback after diskpart CLEAN begins.',
        'The Windows boot/system disk is protected by the storage safety check.'
    )
    $description = Get-DiskMenuLabel -Disk $disk
    if (-not (Confirm-DevintoshDestructiveSelection -ResourceDescription $description -ConfirmationToken "ERASE-DISK-$diskNumber" -WarningLines $warning)) {
        $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE
        throw 'Destructive confirmation was not provided. No disk changes were made.'
    }
    Write-DevintoshStepLog $step "Destructive confirmation for disk #$diskNumber accepted." 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Checking generated Devintosh boot artifacts'
    $ocConfig=Join-Path $efiSource 'OC\config.plist'; $ocLoader=Join-Path $efiSource 'OC\OpenCore.efi'; $bootLoader=Join-Path $efiSource 'BOOT\BOOTx64.efi'
    if (-not (Test-Path -LiteralPath $ocConfig) -or -not (Test-Path -LiteralPath $ocLoader)) { $EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND; throw 'Generated OpenCore EFI/config.plist is missing. Run the OpenCore build/configuration stages first.' }
    $recoveryDmg=Join-Path $recoverySource 'BaseSystem.dmg'; $recoveryChunk=Join-Path $recoverySource 'BaseSystem.chunklist'
    if (-not (Test-Path -LiteralPath $recoveryDmg) -or -not (Test-Path -LiteralPath $recoveryChunk)) { $EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND; throw 'Verified Recovery payload is missing from build/recovery. Run download-recovery.ps1 first.' }
    Write-DevintoshStepLog $step 'OpenCore and Apple Recovery artifacts are present.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Downloading and verifying pinned Clover fallback'
    if (-not (Test-Path -LiteralPath $cloverWorkspace)) { New-Item -ItemType Directory -Path $cloverWorkspace -Force | Out-Null }
    $cloverVersion=Download-AndVerifyClover
    $extracted=Join-Path $cloverWorkspace 'extracted'
    if (Test-Path -LiteralPath $extracted) { Remove-Item -LiteralPath $extracted -Recurse -Force }
    Expand-Archive -LiteralPath $cloverZip -DestinationPath $extracted -Force
    Write-CloverConfig
    Write-DevintoshLog 'INFO' "Clover release $($cloverVersion.version) verified: $($cloverVersion.assetSha256)."
    Write-DevintoshStepLog $step "Clover $($cloverVersion.version) downloaded and SHA-256 verified." 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Creating GPT partition layout'
    $efiLetter=Get-FreeDriveLetter
    $recoveryLetter=Get-FreeDriveLetter -Exclude @($efiLetter)
    Invoke-DiskPart -Commands @(
        "select disk $diskNumber",'clean','convert gpt',
        "create partition efi size=$EfiSizeMB",'format fs=fat32 quick label=EFI',"assign letter=$efiLetter",
        "create partition primary size=$RecoverySizeMB",'format fs=fat32 quick label=OCRECOVERY',"assign letter=$recoveryLetter",'exit'
    ) | Out-Null
    Start-Sleep -Milliseconds 1000
    Write-DevintoshStepLog $step "GPT created with ${EfiSizeMB} MiB EFI and ${RecoverySizeMB} MiB Recovery staging partition." 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Staging OpenCore as the primary UEFI loader'
    $efiRoot="${efiLetter}:\EFI"; New-Item -ItemType Directory -Path $efiRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $efiSource 'OC') -Destination $efiRoot -Recurse -Force
    $bootDir=Join-Path $efiRoot 'BOOT'; New-Item -ItemType Directory -Path $bootDir -Force | Out-Null
    $bootSource=if (Test-Path -LiteralPath $bootLoader){$bootLoader}else{$ocLoader}
    Copy-Item -LiteralPath $bootSource -Destination (Join-Path $bootDir 'BOOTX64.EFI') -Force
    if (-not (Test-Path -LiteralPath (Join-Path $efiRoot 'OC\OpenCore.efi'))) { throw 'OpenCore.efi was not staged on the EFI System Partition.' }
    Write-DevintoshStepLog $step 'OpenCore staged at EFI/BOOT/BOOTX64.EFI and EFI/OC.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Staging Clover fallback selector'
    $cloverEfiRoot=Find-CloverEfiRoot; $cloverSource=Join-Path $cloverEfiRoot 'CLOVER'; $cloverDestination=Join-Path $efiRoot 'CLOVER'
    Copy-Item -LiteralPath $cloverSource -Destination $cloverDestination -Recurse -Force
    Copy-Item -LiteralPath $cloverConfig -Destination (Join-Path $cloverDestination 'config.plist') -Force
    $cloverBinary=Join-Path $cloverDestination 'CLOVERX64.EFI'; if (-not (Test-Path -LiteralPath $cloverBinary)) { $cloverBinary=Join-Path $cloverDestination 'CLOVERX64.efi' }
    if (-not (Test-Path -LiteralPath $cloverBinary)) { throw 'CloverX64 EFI binary was not found after extraction.' }
    Write-DevintoshStepLog $step 'Clover staged at EFI/CLOVER with an explicit OpenCore chain entry.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Staging Apple Recovery payload'
    $recoveryRoot=Join-Path "${recoveryLetter}:" 'com.apple.recovery.boot'; New-Item -ItemType Directory -Path $recoveryRoot -Force | Out-Null
    Copy-Item -LiteralPath $recoveryDmg -Destination $recoveryRoot -Force
    Copy-Item -LiteralPath $recoveryChunk -Destination $recoveryRoot -Force
    $recoverySize=(Get-Item -LiteralPath $recoveryDmg).Length
    if ($recoverySize -le 0) { throw 'BaseSystem.dmg is empty.' }
    Write-DevintoshStepLog $step "Apple Recovery payload staged under com.apple.recovery.boot ($recoverySize bytes)." 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Finalizing boot-disk manifest and leaving APFS space unallocated'
    Write-DevintoshLog 'INFO' 'The remaining target-disk space is intentionally unallocated. macOS Setup/Disk Utility will create the APFS container there.'
    $manifest=[ordered]@{
        schemaVersion=2
        generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o')
        status='ReadyForBootTest'
        diskNumber=$diskNumber
        partitionStyle='GPT'
        efi=@{driveLetter=$efiLetter;sizeMB=$EfiSizeMB;filesystem='FAT32';label='EFI'}
        recovery=@{driveLetter=$recoveryLetter;sizeMB=$RecoverySizeMB;filesystem='FAT32';label='OCRECOVERY';path='com.apple.recovery.boot'}
        remainingSpace='Unallocated'
        openCore=@{path='EFI/OC';bootPath='EFI/BOOT/BOOTX64.EFI'}
        clover=@{version=[string]$cloverVersion.version;path='EFI/CLOVER';config='EFI/CLOVER/config.plist'}
        recoveryPayload=@{BaseSystemDmg=(Get-FileHash -LiteralPath $recoveryDmg -Algorithm SHA256).Hash.ToLowerInvariant();BaseSystemChunklist=(Get-FileHash -LiteralPath $recoveryChunk -Algorithm SHA256).Hash.ToLowerInvariant()}
        windowsBootManagerModified=$false
        rollbackAvailableAfterClean=$false
        note='Storage cleanup is intentionally irreversible after diskpart CLEAN. The target disk was protected and interactively confirmed before CLEAN.'
    }
    if (-not (Test-Path -LiteralPath $workspace)) { New-Item -ItemType Directory -Path $workspace -Force | Out-Null }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $workspace 'boot-disk-manifest.json') -Encoding UTF8
    Write-DevintoshStepLog $step 'Boot disk manifest written; remaining space left unallocated for APFS.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Verifying staged boot files'
    $expected=@(
        (Join-Path $efiRoot 'BOOT\BOOTX64.EFI'),
        (Join-Path $efiRoot 'OC\OpenCore.efi'),
        (Join-Path $efiRoot 'OC\config.plist'),
        (Join-Path $efiRoot 'CLOVER\config.plist'),
        $cloverBinary,
        (Join-Path $recoveryRoot 'BaseSystem.dmg'),
        (Join-Path $recoveryRoot 'BaseSystem.chunklist')
    )
    $missing=@($expected | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($missing.Count -gt 0) { throw "Boot staging verification failed. Missing: $($missing -join ', ')" }
    Write-DevintoshStepLog $step 'EFI, Clover, OpenCore, and Recovery files verified on the target disk.' 'PASS'

    Complete-DevintoshTransaction
    Write-DevintoshProgress $totalSteps $totalSteps 'Boot disk preparation completed'
    Write-DevintoshStepLog $totalSteps "Disk #$diskNumber is boot-ready for the Devintosh test. Reboot and select the firmware/OpenCore or Clover path." 'PASS'
    $EXIT_CODE=$script:EXIT_SUCCESS
}
catch {
    if ($EXIT_CODE -eq $script:EXIT_SUCCESS) { $EXIT_CODE=$script:EXIT_GENERAL_FAILURE }
    Write-DevintoshLog 'ERROR' $_.Exception.Message
    try { Invoke-DevintoshRollback } catch { $EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE; Write-DevintoshLog 'ERROR' $_.Exception.Message }
    throw
}
finally {
    Remove-DriveLetterSafe -Letter $efiLetter
    Remove-DriveLetterSafe -Letter $recoveryLetter
    exit $EXIT_CODE
}
