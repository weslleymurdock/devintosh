#requires -Version 5.1
<#
.SYNOPSIS
    Shared storage discovery and safe-target helpers.

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

function Get-DevintoshPhysicalDisks {
    if (Get-Command Get-Disk -ErrorAction SilentlyContinue) {
        return @(Get-Disk | Where-Object { $_.BusType -ne 'File Backed Virtual' })
    }

    return @(
        Get-CimInstance Win32_DiskDrive | ForEach-Object {
            [pscustomobject]@{
                Number = [int]$_.Index
                FriendlyName = [string]$_.Model
                SerialNumber = [string]$_.SerialNumber
                UniqueId = [string]$_.PNPDeviceID
                Size = [int64]$_.Size
                BusType = [string]$_.InterfaceType
                PartitionStyle = if ($_.Partitions -gt 0) { 'Unknown' } else { 'RAW' }
                OperationalStatus = 'Unknown'
                HealthStatus = 'Unknown'
                IsBoot = $false
                IsSystem = $false
            }
        }
    )
}

function Get-DevintoshDiskByNumber {
    param([Parameter(Mandatory)][int]$Number)
    $disk = Get-DevintoshPhysicalDisks | Where-Object { [int]$_.Number -eq $Number } | Select-Object -First 1
    if ($null -eq $disk) { throw "Physical disk #$Number was not found." }
    return $disk
}

function Test-DevintoshDiskTarget {
    param([Parameter(Mandatory)]$Disk)
    $isBoot = $false
    $isSystem = $false
    if ($Disk.PSObject.Properties.Name -contains 'IsBoot') { $isBoot = [bool]$Disk.IsBoot }
    if ($Disk.PSObject.Properties.Name -contains 'IsSystem') { $isSystem = [bool]$Disk.IsSystem }
    if ($isBoot -or $isSystem) {
        return [pscustomobject]@{ Safe = $false; Reason = 'Target disk contains the active Windows boot/system volume.' }
    }
    return [pscustomobject]@{ Safe = $true; Reason = 'Disk is not marked as the active Windows boot/system disk.' }
}

function New-DevintoshDiskSnapshot {
    param([Parameter(Mandatory)]$Disk)
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::GetCultureInfo('en-US'))
    $path = Join-Path $script:BackupRoot "disk-$($Disk.Number)-$stamp.json"
    $snapshot = [ordered]@{}
    foreach ($property in @('Number','FriendlyName','SerialNumber','UniqueId','Size','BusType','PartitionStyle','OperationalStatus','HealthStatus','IsBoot','IsSystem')) {
        if ($Disk.PSObject.Properties.Name -contains $property) { $snapshot[$property] = $Disk.$property }
    }
    $snapshot | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}
