#requires -Version 5.1
<#
.SYNOPSIS
    Validates the installed Clover EFI chain and configuration from Windows.
.DESCRIPTION
    Report-only validation for a prepared Devintosh boot disk. The script uses DiskPart
    to inspect the selected physical disk and temporarily assigns a drive letter to its
    EFI System Partition. It validates Clover's EFI executable, config.plist XML structure,
    the custom OpenCore chain entry, and the OpenCore EFI payload.

    This does not prove macOS hardware compatibility or guarantee a successful macOS boot.
    It proves that the Windows-visible Clover -> OpenCore EFI chain is structurally ready.

    The active Windows boot/system disk remains protected by the same storage safety checks
    used by prepare-boot-disk.ps1.
.PARAMETER TargetDiskNumber
    Optional physical disk number. If omitted, an interactive safe disk menu is shown.
.PARAMETER Force
    Allows replacement of an existing validation report.
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
. "$PSScriptRoot\lib\rollback.ps1"
. "$PSScriptRoot\lib\storage.ps1"
. "$PSScriptRoot\lib\menu-select.ps1"

$EXIT_CODE = $script:EXIT_SUCCESS
$step = 0
$totalSteps = 8
$reportPath = Join-Path $script:BuildRoot 'opencore\clover-validation-report.json'
$efiLetter = $null
$disk = $null
$diskNumber = -1

function Get-PropertyValue {
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-FreeDriveLetter {
    foreach ($letter in @('S','R','T','U','V','W','X','Y','Z')) {
        if (-not (Get-PSDrive -Name $letter -PSProvider FileSystem -ErrorAction SilentlyContinue)) { return $letter }
    }
    throw 'No free drive letter is available for temporary EFI inspection.'
}

function Invoke-DiskPartReadOnly {
    param([Parameter(Mandatory)][string[]]$Commands)
    $scriptPath = Join-Path $env:TEMP ("devintosh-clover-" + [Guid]::NewGuid().ToString('N') + '.txt')
    try {
        $Commands | Set-Content -LiteralPath $scriptPath -Encoding ASCII
        $output = @(& diskpart.exe /s $scriptPath 2>&1)
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) { throw "diskpart.exe failed with exit code $exitCode. $($output -join ' ')" }
        return $output
    } finally {
        if (Test-Path -LiteralPath $scriptPath) { Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-DiskPartAssign {
    param([Parameter(Mandatory)][int]$Number,[Parameter(Mandatory)][string]$Letter)
    return Invoke-DiskPartReadOnly @("select disk $diskNumber", "select partition $Number", "assign letter=$Letter")
}

function Remove-DriveLetterSafe {
    param([AllowNull()][string]$Letter)
    if ([string]::IsNullOrWhiteSpace($Letter)) { return }
    try { & mountvol.exe "${Letter}:" /D 2>&1 | Out-Null } catch { }
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
    return "Disk #$number | $size | $style | $friendly"
}

function Select-ValidationDisk {
    param([int]$RequestedNumber)
    $disks = @(Get-DevintoshPhysicalDisks)
    if ($disks.Count -eq 0) { $script:EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND; throw 'No physical disks were discovered.' }
    if ($RequestedNumber -ge 0) {
        $requested = $disks | Where-Object { [int](Get-PropertyValue $_ 'Number') -eq $RequestedNumber } | Select-Object -First 1
        if ($null -eq $requested) { $script:EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND; throw "Physical disk #$RequestedNumber was not found." }
        $safety = Test-DevintoshDiskTarget -Disk $requested
        if (-not $safety.Safe) { $script:EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw "Disk #$RequestedNumber cannot be inspected: $($safety.Reason)" }
        return $requested
    }
    $safe = @()
    foreach ($candidate in $disks) {
        $safety = Test-DevintoshDiskTarget -Disk $candidate
        if ($safety.Safe) { $safe += $candidate }
    }
    if ($safe.Count -eq 0) { $script:EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw 'No safe physical disk is available for Clover validation.' }
    $selected = Select-DevintoshMenuItem -Items $safe -Title 'Clover validation disk selection' -Prompt 'Select the prepared Devintosh disk, or Q to cancel' -AllowCancel -LabelScript {
        param($item)
        Get-DiskMenuLabel -Disk $item
    }
    if ($null -eq $selected) { $script:EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw 'Disk selection cancelled by the user.' }
    return $selected
}

function Get-EfiPartitionNumber {
    param([Parameter(Mandatory)][int]$Number)
    $diskpartOutput = @(Invoke-DiskPartReadOnly @("select disk $Number", 'list partition'))
    Write-DevintoshLog 'INFO' 'DiskPart partition inventory:'
    foreach ($line in $diskpartOutput) { Write-DevintoshLog 'INFO' ([string]$line) }

    $partitions = @()
    if (Get-Command Get-Partition -ErrorAction SilentlyContinue) {
        $partitions = @(Get-Partition -DiskNumber $Number -ErrorAction Stop)
        $efi = $partitions | Where-Object {
            ([string](Get-PropertyValue $_ 'Type') -match '(?i)EFI') -or
            ([string](Get-PropertyValue $_ 'GptType') -eq 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b')
        } | Select-Object -First 1
        if ($null -ne $efi) { return [int](Get-PropertyValue $efi 'PartitionNumber') }
    }

    foreach ($line in $diskpartOutput) {
        if ([string]$line -match '^\s*Partition\s+(\d+)\s+.*\bSystem\b') { return [int]$Matches[1] }
    }
    throw "EFI System Partition could not be identified on disk #$Number."
}

function Test-CloverConfig {
    param([Parameter(Mandatory)][string]$Path)
    $result = [ordered]@{ valid=$false; xmlValid=$false; hasGui=$false; hasCustomEntries=$false; hasOpenCoreEntry=$false; openCorePath=$null; errors=@() }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { $result.errors=@('Clover config.plist was not found.'); return [pscustomobject]$result }
    try {
        $xml = New-Object System.Xml.XmlDocument
        $xml.PreserveWhitespace = $true
        $xml.Load($Path)
        $result.xmlValid = $true
        if ($xml.DocumentElement.Name -ne 'plist') { $result.errors += 'Clover config root is not a plist element.'; return [pscustomobject]$result }
        $root = $xml.DocumentElement.SelectSingleNode('/plist/dict')
        if ($null -eq $root) { $result.errors += 'Clover config does not contain a plist dictionary.'; return [pscustomobject]$result }
        $guiKey = $root.SelectSingleNode("key[.='GUI']")
        if ($null -ne $guiKey) { $result.hasGui = $true }
        $customKey = $root.SelectSingleNode("key[.='GUI']/following-sibling::*[1]")
        if ($null -ne $customKey -and $customKey.Name -eq 'dict') {
            $customEntriesKey = $customKey.SelectSingleNode("key[.='Custom']/following-sibling::*[1]")
            if ($null -ne $customEntriesKey -and $customEntriesKey.Name -eq 'dict') {
                $entriesArray = $customEntriesKey.SelectSingleNode("key[.='Entries']/following-sibling::*[1]")
                if ($null -ne $entriesArray -and $entriesArray.Name -eq 'array') {
                    $result.hasCustomEntries = $true
                    foreach ($entry in @($entriesArray.SelectNodes('dict'))) {
                        $pathNode = $entry.SelectSingleNode("key[.='Path']/following-sibling::*[1]")
                        if ($null -ne $pathNode -and [string]$pathNode.InnerText -ieq '\EFI\OC\OpenCore.efi') {
                            $result.hasOpenCoreEntry = $true
                            $result.openCorePath = [string]$pathNode.InnerText
                            break
                        }
                    }
                }
            }
        }
        if (-not $result.hasGui) { $result.errors += 'Clover GUI dictionary is missing.' }
        if (-not $result.hasCustomEntries) { $result.errors += 'Clover GUI custom entries are missing.' }
        if (-not $result.hasOpenCoreEntry) { $result.errors += 'Clover does not contain the expected OpenCore custom entry.' }
        $result.valid = ($result.xmlValid -and $result.hasGui -and $result.hasCustomEntries -and $result.hasOpenCoreEntry)
    } catch {
        $result.errors += "Clover config XML validation failed: $($_.Exception.Message)"
    }
    return [pscustomobject]$result
}

try {
    Start-DevintoshTransaction
    $step++; Write-DevintoshProgress $step $totalSteps 'Checking Windows validation prerequisites'
    if (-not (Test-IsAdministrator)) { $EXIT_CODE=$script:EXIT_INSUFFICIENT_PRIVILEGES; throw 'Administrator privileges are required.' }
    if (-not (Get-Command diskpart.exe -ErrorAction SilentlyContinue)) { $EXIT_CODE=$script:EXIT_DEPENDENCY_FAILURE; throw 'diskpart.exe is required for Clover validation.' }
    if (-not (Get-Command mountvol.exe -ErrorAction SilentlyContinue)) { $EXIT_CODE=$script:EXIT_DEPENDENCY_FAILURE; throw 'mountvol.exe is required for Clover validation.' }
    Write-DevintoshStepLog $step 'Windows validation prerequisites are available.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Selecting and safety-checking the prepared Devintosh disk'
    $disk = Select-ValidationDisk -RequestedNumber $TargetDiskNumber
    $diskNumber = [int](Get-PropertyValue $disk 'Number')
    Write-DevintoshStepLog $step "Disk #$diskNumber selected and passed boot/system-disk protection." 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Inspecting disk partitions with DiskPart'
    $efiPartitionNumber = Get-EfiPartitionNumber -Number $diskNumber
    Write-DevintoshStepLog $step "DiskPart identified EFI System Partition #$efiPartitionNumber on disk #$diskNumber." 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Mounting the EFI System Partition for read-only validation'
    $efiLetter = Get-FreeDriveLetter
    $assignOutput = Invoke-DiskPartAssign -Number $efiPartitionNumber -Letter $efiLetter
    Write-DevintoshLog 'INFO' "DiskPart assigned temporary EFI drive ${efiLetter}:."
    if (-not (Test-Path -LiteralPath "${efiLetter}:\EFI")) { $EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND; throw "EFI directory was not accessible on ${efiLetter}:." }
    Write-DevintoshStepLog $step "EFI System Partition mounted temporarily as ${efiLetter}:." 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Validating Clover EFI payload and OpenCore chain'
    $cloverRoot = "${efiLetter}:\EFI\CLOVER"
    $cloverEfi = Join-Path $cloverRoot 'CLOVERX64.EFI'
    $cloverConfig = Join-Path $cloverRoot 'config.plist'
    $openCoreEfi = "${efiLetter}:\EFI\OC\OpenCore.efi"
    $checks = [ordered]@{
        cloverDirectory = Test-Path -LiteralPath $cloverRoot -PathType Container
        cloverEfi = Test-Path -LiteralPath $cloverEfi -PathType Leaf
        cloverConfig = Test-Path -LiteralPath $cloverConfig -PathType Leaf
        openCoreEfi = Test-Path -LiteralPath $openCoreEfi -PathType Leaf
    }
    foreach ($name in $checks.Keys) { Write-DevintoshLog 'INFO' ("{0}: {1}" -f $name,$checks[$name]) }
    if (-not $checks.cloverDirectory -or -not $checks.cloverEfi -or -not $checks.cloverConfig -or -not $checks.openCoreEfi) {
        $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE
        throw 'Clover/OpenCore EFI payload is incomplete.'
    }
    $configResult = Test-CloverConfig -Path $cloverConfig
    if (-not $configResult.valid) {
        $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE
        throw ("Clover config.plist validation failed: {0}" -f (@($configResult.errors) -join '; '))
    }
    Write-DevintoshStepLog $step 'Clover EFI payload and Clover -> OpenCore configuration chain are structurally valid.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Writing Clover validation report'
    if ((Test-Path -LiteralPath $reportPath) -and -not $Force) { $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw "Validation report already exists. Use -Force to replace it: $reportPath" }
    $report = [ordered]@{
        schemaVersion = 1
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        diskNumber = $diskNumber
        efiPartitionNumber = $efiPartitionNumber
        validationTarget = 'Windows-mounted-efi'
        status = 'Valid'
        bootChain = @('UEFI','Clover','OpenCore','macOS')
        clover = [ordered]@{ efiPath='EFI/CLOVER/CLOVERX64.EFI'; configPath='EFI/CLOVER/config.plist'; configValid=$configResult.valid; openCoreEntry=$configResult.openCorePath }
        openCore = [ordered]@{ efiPath='EFI/OC/OpenCore.efi'; present=$checks.openCoreEfi }
        interpretation = 'Clover EFI and config.plist are structurally valid and contain the expected Clover-to-OpenCore chain. This does not prove macOS hardware compatibility.'
    }
    $parent = Split-Path -Parent $reportPath
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    Write-DevintoshStepLog $step "Clover validation report written to $reportPath." 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Finalizing Clover validation'
    Complete-DevintoshTransaction
    Complete-DevintoshProgress 'Clover validation completed'
    Write-DevintoshStepLog $step 'Clover boot chain is structurally valid for the selected disk.' 'PASS'
    exit $script:EXIT_SUCCESS
}
catch {
    Write-DevintoshStepLog $step "Clover validation failed: $($_.Exception.Message)" 'FAIL'
    Write-DevintoshLog 'ERROR' $_.Exception.ToString()
    $rollbackOk = Invoke-DevintoshRollback
    if (-not $rollbackOk) { $EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE }
    exit $EXIT_CODE
}
finally {
    Remove-DriveLetterSafe -Letter $efiLetter
}
