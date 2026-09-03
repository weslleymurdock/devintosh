#requires -Version 5.1
<#
.SYNOPSIS
    Destructively prepares an empty physical disk for a Devintosh UEFI boot test.
.DESCRIPTION
    Creates a GPT disk with a 512 MiB FAT32 EFI System Partition and a 2 GiB FAT32
    macOS Recovery staging partition. The remaining disk space is intentionally left
    unallocated so macOS Disk Utility can create the final APFS container during setup.

    OpenCore is installed as the primary UEFI fallback loader at EFI/BOOT/BOOTX64.EFI.
    Clover is installed under EFI/CLOVER as a fallback selector and is configured with
    an explicit OpenCore chain entry. Windows remains untouched.

    This script refuses disks that already contain partitions or that Windows marks as
    boot/system disks. It is therefore intended for a genuinely empty target disk.

.PARAMETER TargetDiskNumber
    Physical Windows disk number to prepare.
.PARAMETER Force
    Required acknowledgement that the target disk will be repartitioned.
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
    [Parameter(Mandatory = $true)][int]$TargetDiskNumber,
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
    foreach ($letter in @('S','R','T','U','V','W','X','Y','Z')) {
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
        if ($exitCode -ne 0) {
            throw "diskpart.exe failed with exit code $exitCode. $($output -join ' ')"
        }
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

function Assert-EmptyRawDisk {
    param([Parameter(Mandatory)]$Target)
    $style = [string](Get-PropertyValue $Target 'PartitionStyle')
    $parts = @(Get-PartitionForDisk $Target.Number)
    $volumes = @()
    if (Get-Command Get-Volume -ErrorAction SilentlyContinue) {
        $volumes = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.Path })
    }
    if ($style -notin @('RAW','')) {
        $script:EXIT_CODE = $script:EXIT_VALIDATION_FAILURE
        throw "Target disk #$($Target.Number) is not RAW/uninitialized (PartitionStyle=$style). Refusing to erase an initialized disk."
    }
    if ($parts.Count -gt 0) {
        $script:EXIT_CODE = $script:EXIT_VALIDATION_FAILURE
        throw "Target disk #$($Target.Number) already has $($parts.Count) partition(s). Refusing to erase it."
    }
}

function Download-AndVerifyClover {
    $version = Get-Content -LiteralPath $cloverVersionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $assetUrl = [string]$version.assetUrl
    $expected = ([string]$version.assetSha256).ToLowerInvariant()
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
    $matches = @(
        Get-ChildItem -LiteralPath $cloverWorkspace -Directory -Recurse -ErrorAction Stop |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'CLOVER') -PathType Container }
    )
    if ($matches.Count -eq 0) {
        $direct = Join-Path $cloverWorkspace 'EFI'
        if (Test-Path -LiteralPath (Join-Path $direct 'CLOVER') -PathType Container) { return $direct }
        throw 'CloverV2 archive does not contain an EFI/CLOVER directory.'
    }
    return $matches[0].FullName
}

function Write-CloverConfig {
    @'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Boot</key>
    <dict>
        <key>Timeout</key>
        <integer>-1</integer>
        <key>Debug</key>
        <true/>
    </dict>
    <key>GUI</key>
    <dict>
        <key>Scan</key>
        <dict>
            <key>Entries</key>
            <true/>
            <key>Tool</key>
            <true/>
        </dict>
        <key>Custom</key>
        <dict>
            <key>Entries</key>
            <array>
                <dict>
                    <key>Disabled</key>
                    <false/>
                    <key>FullTitle</key>
                    <string>OpenCore</string>
                    <key>Path</key>
                    <string>\EFI\OC\OpenCore.efi</string>
                    <key>Type</key>
                    <string>Other</string>
                    <key>Volume</key>
                    <string>EFI</string>
                    <key>VolumeType</key>
                    <string>Internal</string>
                </dict>
            </array>
        </dict>
    </dict>
    <key>SMBIOS</key>
    <dict/>
    <key>SystemParameters</key>
    <dict>
        <key>InjectKexts</key>
        <false/>
    </dict>
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

    $step++
    Write-DevintoshProgress $step $totalSteps 'Checking administrator privileges and parameters'
    if (-not (Test-IsAdministrator)) {
        $EXIT_CODE = $script:EXIT_INSUFFICIENT_PRIVILEGES
        throw 'Run prepare-boot-disk.ps1 from an elevated PowerShell session.'
    }
    if (-not $Force) {
        $EXIT_CODE = $script:EXIT_VALIDATION_FAILURE
        throw 'This stage repartitions the target disk. Re-run with -Force after confirming the disk number.'
    }
    if ($EfiSizeMB + $RecoverySizeMB -ge 16384) {
        $EXIT_CODE = $script:EXIT_UNSUPPORTED_CONFIGURATION
        throw 'EFI plus Recovery staging partitions consume an unsupported amount of the target disk.'
    }
    Write-DevintoshStepLog $step 'Administrator privileges and destructive-stage acknowledgement passed.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Resolving target physical disk'
    $disk = Get-DevintoshDiskByNumber -Number $TargetDiskNumber
    $safety = Test-DevintoshDiskTarget -Disk $disk
    if (-not $safety.Safe) {
        $EXIT_CODE = $script:EXIT_VALIDATION_FAILURE
        throw $safety.Reason
    }
    Assert-EmptyRawDisk -Target $disk
    $snapshot = New-DevintoshDiskSnapshot -Disk $disk
    Write-DevintoshLog 'INFO' "Target disk: #$($disk.Number); $($disk.FriendlyName); $([math]::Round([double]$disk.Size / 1GB, 2)) GiB."
    Write-DevintoshLog 'INFO' "Disk snapshot: $snapshot"
    Write-DevintoshStepLog $step "Empty RAW target disk #$($disk.Number) selected." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Checking generated Devintosh boot artifacts'
    $ocConfig = Join-Path $efiSource 'OC\config.plist'
    $ocLoader = Join-Path $efiSource 'OC\OpenCore.efi'
    $bootLoader = Join-Path $efiSource 'BOOT\BOOTx64.efi'
    if (-not (Test-Path -LiteralPath $ocConfig) -or -not (Test-Path -LiteralPath $ocLoader)) {
        $EXIT_CODE = $script:EXIT_TARGET_NOT_FOUND
        throw 'Generated OpenCore EFI/config.plist is missing. Run build/configuration/composition/validation stages first.'
    }
    $recoveryDmg = Join-Path $recoverySource 'BaseSystem.dmg'
    $recoveryChunk = Join-Path $recoverySource 'BaseSystem.chunklist'
    if (-not (Test-Path -LiteralPath $recoveryDmg) -or -not (Test-Path -LiteralPath $recoveryChunk)) {
        $EXIT_CODE = $script:EXIT_TARGET_NOT_FOUND
        throw 'Verified Recovery payload is missing from build/recovery. Run download-recovery.ps1 first.'
    }
    Write-DevintoshStepLog $step 'OpenCore and Apple Recovery artifacts are present.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Downloading and verifying pinned Clover fallback'
    if (-not (Test-Path -LiteralPath $cloverWorkspace)) { New-Item -ItemType Directory -Path $cloverWorkspace -Force | Out-Null }
    $cloverVersion = Download-AndVerifyClover
    if (Test-Path -LiteralPath (Join-Path $cloverWorkspace 'extracted')) { Remove-Item -LiteralPath (Join-Path $cloverWorkspace 'extracted') -Recurse -Force }
    Expand-Archive -LiteralPath $cloverZip -DestinationPath (Join-Path $cloverWorkspace 'extracted') -Force
    Write-CloverConfig
    Write-DevintoshLog 'INFO' "Clover release $($cloverVersion.version) verified: $($cloverVersion.assetSha256)."
    Write-DevintoshStepLog $step "Clover $($cloverVersion.version) downloaded and SHA-256 verified." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Creating GPT partition layout'
    $efiLetter = Get-FreeDriveLetter
    $recoveryLetter = Get-FreeDriveLetter
    if ($recoveryLetter -eq $efiLetter) { $recoveryLetter = Get-FreeDriveLetter }
    $diskpartCommands = @(
        "select disk $TargetDiskNumber",
        'clean',
        'convert gpt',
        "create partition efi size=$EfiSizeMB",
        "format fs=fat32 quick label=EFI",
        "assign letter=$efiLetter",
        "create partition primary size=$RecoverySizeMB",
        "format fs=fat32 quick label=OCRECOVERY",
        "assign letter=$recoveryLetter",
        'exit'
    )
    Invoke-DiskPart -Commands $diskpartCommands | Out-Null
    Start-Sleep -Milliseconds 750
    Write-DevintoshStepLog $step "GPT created with ${EfiSizeMB} MiB EFI and ${RecoverySizeMB} MiB Recovery staging partition." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Staging OpenCore as the primary UEFI loader'
    $efiRoot = "${efiLetter}:\EFI"
    New-Item -ItemType Directory -Path $efiRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $efiSource 'OC') -Destination $efiRoot -Recurse -Force
    $bootDir = Join-Path $efiRoot 'BOOT'
    New-Item -ItemType Directory -Path $bootDir -Force | Out-Null
    $bootSource = if (Test-Path -LiteralPath $bootLoader) { $bootLoader } else { $ocLoader }
    Copy-Item -LiteralPath $bootSource -Destination (Join-Path $bootDir 'BOOTX64.EFI') -Force
    if (-not (Test-Path -LiteralPath (Join-Path $efiRoot 'OC\OpenCore.efi'))) { throw 'OpenCore.efi was not staged on the EFI System Partition.' }
    Write-DevintoshStepLog $step 'OpenCore staged at EFI/BOOT/BOOTX64.EFI and EFI/OC.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Staging Clover fallback selector'
    $cloverEfiRoot = Find-CloverEfiRoot
    $cloverSource = Join-Path $cloverEfiRoot 'CLOVER'
    $cloverDestination = Join-Path $efiRoot 'CLOVER'
    Copy-Item -LiteralPath $cloverSource -Destination $cloverDestination -Recurse -Force
    Copy-Item -LiteralPath $cloverConfig -Destination (Join-Path $cloverDestination 'config.plist') -Force
    $cloverBinary = Join-Path $cloverDestination 'CLOVERX64.EFI'
    if (-not (Test-Path -LiteralPath $cloverBinary)) {
        $cloverBinary = Join-Path $cloverDestination 'CLOVERX64.efi'
    }
    if (-not (Test-Path -LiteralPath $cloverBinary)) { throw 'CloverX64 EFI binary was not found after extraction.' }
    Write-DevintoshStepLog $step 'Clover staged at EFI/CLOVER with an explicit OpenCore chain entry.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Staging Apple Recovery payload'
    $recoveryRoot = Join-Path "${recoveryLetter}:" 'com.apple.recovery.boot'
    New-Item -ItemType Directory -Path $recoveryRoot -Force | Out-Null
    Copy-Item -LiteralPath $recoveryDmg -Destination $recoveryRoot -Force
    Copy-Item -LiteralPath $recoveryChunk -Destination $recoveryRoot -Force
    $recoverySize = (Get-Item -LiteralPath $recoveryDmg).Length
    if ($recoverySize -le 0) { throw 'BaseSystem.dmg is empty.' }
    Write-DevintoshStepLog $step "Apple Recovery payload staged under com.apple.recovery.boot ($recoverySize bytes)." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Leaving remaining disk space unallocated for APFS'
    Write-DevintoshLog 'INFO' 'The remaining target-disk space is intentionally unallocated. Do not create NTFS/exFAT here.'
    Write-DevintoshLog 'INFO' 'macOS Setup > Disk Utility must create the APFS container from the remaining space.'
    $manifest = [ordered]@{
        schemaVersion = 1
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        diskNumber = $TargetDiskNumber
        partitionScheme = 'GPT'
        efi = [ordered]@{label='EFI';sizeMiB=$EfiSizeMB;driveLetter=$efiLetter;role='UEFI System Partition'}
        recoveryStaging = [ordered]@{label='OCRECOVERY';sizeMiB=$RecoverySizeMB;driveLetter=$recoveryLetter;role='OpenCore/macOS Recovery staging; not an Apple APFS Recovery partition'}
        remainingSpace = 'unallocated'
        primaryLoader = 'OpenCore'
        fallbackSelector = 'Clover'
        cloverVersion = [string]$cloverVersion.version
        cloverSha256 = [string]$cloverVersion.assetSha256
        generatedFiles = @('EFI/BOOT/BOOTX64.EFI','EFI/OC/OpenCore.efi','EFI/OC/config.plist','EFI/CLOVER/CLOVERX64.EFI','EFI/CLOVER/config.plist','com.apple.recovery.boot/BaseSystem.dmg','com.apple.recovery.boot/BaseSystem.chunklist')
        windowsModified = $false
        apfsCreatedByWindows = $false
        notes = @('Apple Partition Map is not used on Intel UEFI systems; GPT is the correct partition scheme.','OCRECOVERY is a FAT32 staging volume, not a native Apple Recovery APFS volume.','No Windows BCD or Windows system partition was modified.','No SMBIOS unique identifiers were generated.')
    }
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $workspace 'boot-disk-manifest.json') -Encoding UTF8
    Write-DevintoshStepLog $step 'Target disk prepared with APFS space intentionally left for macOS Disk Utility.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Verifying boot-ready file structure'
    $required = @(
        (Join-Path $efiRoot 'BOOT\BOOTX64.EFI'),
        (Join-Path $efiRoot 'OC\OpenCore.efi'),
        (Join-Path $efiRoot 'OC\config.plist'),
        (Join-Path $efiRoot 'CLOVER\CLOVERX64.EFI'),
        (Join-Path $efiRoot 'CLOVER\config.plist'),
        (Join-Path $recoveryRoot 'BaseSystem.dmg'),
        (Join-Path $recoveryRoot 'BaseSystem.chunklist')
    )
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($missing.Count -gt 0) {
        $EXIT_CODE = $script:EXIT_ASSET_INTEGRITY_FAILURE
        throw "Boot-ready verification failed. Missing: $($missing -join ', ')"
    }
    Write-DevintoshStepLog $step 'EFI, OpenCore, Clover and Recovery staging files are present.' 'PASS'

    Complete-DevintoshTransaction
    Complete-DevintoshProgress 'boot disk preparation complete'
    $EXIT_CODE = $script:EXIT_SUCCESS
}
catch {
    Write-DevintoshLog 'ERROR' "Boot disk preparation failed: $($_.Exception.Message)"
    try { $ok = Invoke-DevintoshRollback; if (-not $ok) { $EXIT_CODE = $script:EXIT_ROLLBACK_FAILURE } } catch { $EXIT_CODE = $script:EXIT_ROLLBACK_FAILURE }
    if ($EXIT_CODE -eq $script:EXIT_SUCCESS) { $EXIT_CODE = $script:EXIT_GENERAL_FAILURE }
}
finally {
    Remove-DriveLetterSafe -Letter $efiLetter
    Remove-DriveLetterSafe -Letter $recoveryLetter
}
exit $EXIT_CODE
