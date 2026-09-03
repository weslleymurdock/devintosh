#requires -Version 5.1
<#
.SYNOPSIS
    Interactively prepares a physical disk for a Devintosh UEFI boot test.
.DESCRIPTION
    Creates GPT + EFI + Recovery staging and leaves the remaining space unallocated.

    Existing non-system disks (including NTFS data disks) may be selected and will be
    repartitioned only after an explicit destructive confirmation. The active Windows
    boot/system disk is always protected. There is intentionally no switch that disables
    this protection: -Force and the typed confirmation authorize destruction only after
    the target has passed the Windows storage safety check.

    If the desired target is the disk from which the current Windows session is running,
    Windows must first be booted from an external Windows PE/Windows Setup environment
    or another operating system. Do not attempt to disable the protection from the live
    Windows installation.

.PARAMETER TargetDiskNumber
    Optional physical Windows disk number. If omitted, an interactive safe disk menu is shown.
.PARAMETER Force
    Optional explicit acknowledgement that the selected disk will be repartitioned. The
    final typed destructive confirmation remains mandatory.
.PARAMETER EfiSizeMB
    EFI System Partition size. Default 512 MiB.
.PARAMETER RecoverySizeMB
    FAT32 Recovery staging size. Default 2048 MiB.
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
        if (-not (Get-PSDrive -Name $letter -PSProvider FileSystem -ErrorAction SilentlyContinue)) { return $letter }
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
    } finally {
        if (Test-Path -LiteralPath $scriptPath) { Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue }
    }
}

function Get-PartitionForDisk {
    param([int]$Number)
    if (Get-Command Get-Partition -ErrorAction SilentlyContinue) { return @(Get-Partition -DiskNumber $Number -ErrorAction SilentlyContinue) }
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
    if ($disks.Count -eq 0) { $script:EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND; throw 'No physical disks were discovered.' }

    if ($RequestedNumber -ge 0) {
        $requested = $disks | Where-Object { [int](Get-PropertyValue $_ 'Number') -eq $RequestedNumber } | Select-Object -First 1
        if ($null -eq $requested) { $script:EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND; throw "Physical disk #$RequestedNumber was not found." }
        $safety = Test-DevintoshDiskTarget -Disk $requested
        if (-not $safety.Safe) {
            $script:EXIT_CODE=$script:EXIT_VALIDATION_FAILURE
            throw "Disk #$RequestedNumber cannot be selected: $($safety.Reason)"
        }
        return $requested
    }

    $safeCandidates = @()
    foreach ($candidate in $disks) {
        $safety = Test-DevintoshDiskTarget -Disk $candidate
        if ($safety.Safe) { $safeCandidates += $candidate }
        else { Write-DevintoshLog 'WARN' "Disk #$((Get-PropertyValue $candidate 'Number')) excluded from destructive selection: $($safety.Reason)" }
    }
    if ($safeCandidates.Count -eq 0) { $script:EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw 'No disk is eligible for destructive preparation. The active Windows boot/system disk is intentionally protected.' }

    $selected = Select-DevintoshMenuItem -Items $safeCandidates -Title 'Devintosh boot disk selection' -Prompt 'Select the disk number shown in the menu, or Q to cancel' -AllowCancel -LabelScript {
        param($item)
        Get-DiskMenuLabel -Disk $item
    }
    if ($null -eq $selected) { $script:EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw 'Disk selection cancelled by the user.' }
    return $selected
}

function Download-AndVerifyClover {
    $version = Get-Content -LiteralPath $cloverVersionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $assetUrl=[string]$version.assetUrl; $expected=([string]$version.assetSha256).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($assetUrl) -or [string]::IsNullOrWhiteSpace($expected)) { $script:EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE; throw 'Clover version manifest is missing assetUrl or assetSha256.' }
    $parent=Split-Path -Parent $cloverZip; if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Invoke-WebRequest -Uri $assetUrl -UseBasicParsing -OutFile $cloverZip
    $actual=(Get-FileHash -LiteralPath $cloverZip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { $script:EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE; throw "Clover SHA-256 mismatch. Expected $expected; got $actual." }
    return $version
}

function Find-CloverEfiRoot {
    $extractedRoot=Join-Path $cloverWorkspace 'extracted'
    $matches=@(Get-ChildItem -LiteralPath $extractedRoot -Directory -Recurse -ErrorAction Stop | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'CLOVER') -PathType Container })
    if ($matches.Count -gt 0) { return $matches[0].FullName }
    $direct=Join-Path $extractedRoot 'EFI'; if (Test-Path -LiteralPath (Join-Path $direct 'CLOVER') -PathType Container) { return $direct }
    throw 'Clover archive does not contain an EFI/CLOVER directory.'
}

function Write-CloverConfig {
@'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Boot</key><dict><key>Timeout</key><integer>-1</integer><key>Debug</key><true/></dict>
<key>GUI</key><dict><key>Scan</key><dict><key>Entries</key><true/><key>Tool</key><true/></dict><key>Custom</key><dict><key>Entries</key><array><dict><key>Disabled</key><false/><key>FullTitle</key><string>OpenCore</string><key>Path</key><string>\EFI\OC\OpenCore.efi</string><key>Type</key><string>Other</string><key>Volume</key><string>EFI</string><key>VolumeType</key><string>Internal</string></dict></array></dict></dict>
<key>SMBIOS</key><dict/><key>SystemParameters</key><dict><key>InjectKexts</key><false/></dict>
</dict></plist>
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
    Write-DevintoshStepLog $step 'Administrator privileges and safety prerequisites passed.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Selecting a physical target disk'
    $disk=Select-TargetDisk -RequestedNumber $TargetDiskNumber
    $diskNumber=[int](Get-PropertyValue $disk 'Number')
    $safety=Test-DevintoshDiskTarget -Disk $disk
    if (-not $safety.Safe) { $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw $safety.Reason }
    $snapshot=New-DevintoshDiskSnapshot -Disk $disk
    Write-DevintoshLog 'INFO' "Target disk: #$diskNumber; $(Get-DiskMenuLabel -Disk $disk)"
    Write-DevintoshLog 'INFO' "Disk snapshot: $snapshot"
    Write-DevintoshStepLog $step "Disk #$diskNumber selected and passed boot/system-disk protection." 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Reconfirming the destructive target'
    $partitionList=@(Get-PartitionForDisk $diskNumber)
    $partitionSummary=if ($partitionList.Count -eq 0) { 'No existing partitions.' } else { "$($partitionList.Count) existing partition(s) WILL BE DESTROYED." }
    $warning=@("Disk #$diskNumber will be CLEANED and converted to GPT.",$partitionSummary,'All data currently stored on this disk will be lost.','There is no reliable rollback after diskpart CLEAN begins.')
    $description=Get-DiskMenuLabel -Disk $disk
    if (-not (Confirm-DevintoshDestructiveSelection -ResourceDescription $description -ConfirmationToken "ERASE-DISK-$diskNumber" -WarningLines $warning)) { $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw 'Destructive confirmation was not provided. No disk changes were made.' }
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
    $extracted=Join-Path $cloverWorkspace 'extracted'; if (Test-Path -LiteralPath $extracted) { Remove-Item -LiteralPath $extracted -Recurse -Force }
    Expand-Archive -LiteralPath $cloverZip -DestinationPath $extracted -Force
    Write-CloverConfig
    Write-DevintoshStepLog $step "Clover $($cloverVersion.version) downloaded and SHA-256 verified." 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Creating GPT partition layout'
    $efiLetter=Get-FreeDriveLetter; $recoveryLetter=Get-FreeDriveLetter -Exclude @($efiLetter)
    Invoke-DiskPart -Commands @("select disk $diskNumber",'clean','convert gpt',"create partition efi size=$EfiSizeMB",'format fs=fat32 quick label=EFI',"assign letter=$efiLetter","create partition primary size=$RecoverySizeMB",'format fs=fat32 quick label=OCRECOVERY',"assign letter=$recoveryLetter",'exit') | Out-Null
    Start-Sleep -Milliseconds 750
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
    Copy-Item -LiteralPath $recoveryDmg -Destination $recoveryRoot -Force; Copy-Item -LiteralPath $recoveryChunk -Destination $recoveryRoot -Force
    $recoverySize=(Get-Item -LiteralPath $recoveryDmg).Length; if ($recoverySize -le 0) { throw 'BaseSystem.dmg is empty.' }
    Write-DevintoshStepLog $step "Apple Recovery payload staged under com.apple.recovery.boot ($recoverySize bytes)." 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Leaving remaining disk space unallocated for APFS'
    Write-DevintoshLog 'INFO' 'Remaining target-disk space is intentionally unallocated. macOS Setup will create the APFS container there.'
    $manifest=[ordered]@{schemaVersion=1;generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o');diskNumber=$diskNumber;diskModel=[string]$disk.FriendlyName;diskSizeGiB=[math]::Round([double]$disk.Size/1GB,2);partitionStyle='GPT';efiSizeMiB=$EfiSizeMB;recoverySizeMiB=$RecoverySizeMB;efiDriveLetter=$efiLetter;recoveryDriveLetter=$recoveryLetter;cloverVersion=[string]$cloverVersion.version;openCorePrimary='EFI/BOOT/BOOTX64.EFI';cloverFallback='EFI/CLOVER/CLOVERX64.EFI';recoveryPath='com.apple.recovery.boot';apfsSpace='unallocated';destructiveConfirmation="ERASE-DISK-$diskNumber";rollback='Not possible after diskpart CLEAN; safety is enforced before CLEAN.'}
    $manifestPath=Join-Path $workspace 'boot-disk-manifest.json'; $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Write-DevintoshStepLog $step 'Remaining disk space left unallocated for macOS APFS creation.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Verifying boot-disk contents'
    foreach ($required in @((Join-Path $efiRoot 'BOOT\BOOTX64.EFI'),(Join-Path $efiRoot 'OC\OpenCore.efi'),(Join-Path $efiRoot 'OC\config.plist'),(Join-Path $efiRoot 'CLOVER\CLOVERX64.EFI'),(Join-Path $recoveryRoot 'BaseSystem.dmg'),(Join-Path $recoveryRoot 'BaseSystem.chunklist'))) { if (-not (Test-Path -LiteralPath $required)) { throw "Required boot-disk artifact is missing: $required" } }
    Write-DevintoshStepLog $step 'EFI, OpenCore, Clover and Recovery payload verification passed.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Finalizing disk preparation'
    Remove-DriveLetterSafe $efiLetter; Remove-DriveLetterSafe $recoveryLetter
    Complete-DevintoshTransaction
    Write-DevintoshStepLog $step 'Boot disk preparation completed successfully.' 'PASS'
    $EXIT_CODE=$script:EXIT_SUCCESS
}
catch {
    try { Invoke-DevintoshRollback } catch { $EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE }
    Write-DevintoshLog 'ERROR' $_.Exception.Message
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Remove-DriveLetterSafe $efiLetter; Remove-DriveLetterSafe $recoveryLetter
}

exit $EXIT_CODE
