#requires -Version 5.1
<#
.SYNOPSIS
    Resolves USB controller capability profiles without generating a macOS USB port map.
.DESCRIPTION
    Hardware-agnostic USB stage. Windows hardware inventory is used only to select
    declarative controller capability profiles. A macOS USB port map is never inferred
    from the Windows PnP tree because Windows and macOS expose different port topology.

    The stage produces a transactional resolution report. A later native macOS validation
    stage may provide the exact port inventory and an explicitly validated mapping.
.PARAMETER Force
    Replaces an existing generated resolution report after creating a backup.
#>
[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\console.ps1"
. "$PSScriptRoot\lib\logging.ps1"
. "$PSScriptRoot\lib\progress.ps1"
. "$PSScriptRoot\lib\rollback.ps1"

$EXIT_CODE = $script:EXIT_SUCCESS
$step = 0
$totalSteps = 7
$outputRoot = Join-Path $script:BuildRoot 'opencore'
$hardwarePath = Join-Path $outputRoot 'hardware-detected.json'
$reportPath = Join-Path $outputRoot 'usb-resolution.json'
$backupRoot = Join-Path $script:BackupRoot 'usb'
$profileRoot = Join-Path $script:RepoRoot 'config\hardware\usb'

function Get-PropertyValue {
    param([AllowNull()][object]$Object,[Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-ArraySafe {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return @() }
    return @($Value)
}

function Test-StringEquals {
    param([AllowNull()]$Actual,[AllowNull()]$Expected)
    if ($null -eq $Actual -or $null -eq $Expected) { return $false }
    return ([string]$Actual).Trim().Equals(([string]$Expected).Trim(),[StringComparison]::OrdinalIgnoreCase)
}

function Test-CollectionIdentity {
    param([AllowNull()]$Devices,[AllowNull()]$VendorId,[AllowNull()]$DeviceIds,[AllowNull()]$SubsystemIds)
    $devicesArray = @(Get-ArraySafe $Devices)
    if ($devicesArray.Count -eq 0) { return $false }

    $deviceIdArray = @(Get-ArraySafe $DeviceIds | ForEach-Object { ([string]$_).Trim().ToUpperInvariant() })
    $subsystemArray = @(Get-ArraySafe $SubsystemIds | ForEach-Object { ([string]$_).Trim().ToUpperInvariant() })

    foreach ($device in $devicesArray) {
        $deviceVendor = Get-PropertyValue $device 'VendorId'
        $deviceId = Get-PropertyValue $device 'DeviceId'
        $subsystem = Get-PropertyValue $device 'SubsystemId'

        if ($null -ne $VendorId -and -not (Test-StringEquals $deviceVendor $VendorId)) { continue }
        if ($deviceIdArray.Count -gt 0 -and $deviceIdArray -notcontains ([string]$deviceId).Trim().ToUpperInvariant()) { continue }
        if ($subsystemArray.Count -gt 0 -and $subsystemArray -notcontains ([string]$subsystem).Trim().ToUpperInvariant()) { continue }
        return $true
    }
    return $false
}

function Test-UsbProfileMatch {
    param([Parameter(Mandatory)]$Hardware,[Parameter(Mandatory)]$Profile)
    $rule = Get-PropertyValue $Profile 'match'
    if ($null -eq $rule) { return $false }

    $usb = Get-PropertyValue $Hardware 'usb'
    if ($null -eq $usb) { return $false }
    $devices = Get-PropertyValue $usb 'pnp'

    $vendorId = Get-PropertyValue $rule 'usbVendorId'
    $deviceIds = Get-PropertyValue $rule 'usbDeviceIds'
    $subsystemIds = Get-PropertyValue $rule 'usbSubsystemIds'
    if ($null -ne $vendorId -or $null -ne $deviceIds -or $null -ne $subsystemIds) {
        return Test-CollectionIdentity $devices $vendorId $deviceIds $subsystemIds
    }

    $anyOf = @(Get-ArraySafe (Get-PropertyValue $rule 'anyOf'))
    if ($anyOf.Count -gt 0) {
        foreach ($alternative in $anyOf) {
            if (Test-CollectionIdentity $devices (Get-PropertyValue $alternative 'usbVendorId') (Get-PropertyValue $alternative 'usbDeviceIds') (Get-PropertyValue $alternative 'usbSubsystemIds')) {
                return $true
            }
        }
    }
    return $false
}

function Get-UsbProfiles {
    $result = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $profileRoot -PathType Container)) { return @() }

    foreach ($file in @(Get-ChildItem -LiteralPath $profileRoot -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue)) {
        try {
            $profile = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $id = Get-PropertyValue $profile 'id'
            $match = Get-PropertyValue $profile 'match'
            $capabilities = Get-PropertyValue $profile 'capabilities'
            if ($null -ne $id -and $null -ne $match -and $null -ne $capabilities -and [bool](Get-PropertyValue $capabilities 'usb')) {
                [void]$result.Add($profile)
            }
        } catch {
            Write-DevintoshLog 'WARN' "Ignoring invalid USB profile $($file.FullName): $($_.Exception.Message)"
        }
    }
    return @($result.ToArray())
}

function Write-ReportTransactional {
    param([Parameter(Mandatory)]$Report)
    if (-not (Test-Path -LiteralPath $outputRoot -PathType Container)) { [void](New-Item -ItemType Directory -Path $outputRoot -Force) }
    if (-not (Test-Path -LiteralPath $backupRoot -PathType Container)) { [void](New-Item -ItemType Directory -Path $backupRoot -Force) }

    if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff',[Globalization.CultureInfo]::InvariantCulture)
        $backup = Join-Path $backupRoot ("usb-resolution-{0}.json" -f $stamp)
        Copy-Item -LiteralPath $reportPath -Destination $backup -Force
        Add-DevintoshRollbackAction -Name 'Restore previous USB resolution report' -Action {
            Copy-Item -LiteralPath $backup -Destination $reportPath -Force
        }
    } else {
        Add-DevintoshRollbackAction -Name 'Remove newly created USB resolution report' -Action {
            if (Test-Path -LiteralPath $reportPath -PathType Leaf) { Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue }
        }
    }

    $temp = "$reportPath.tmp"
    try {
        $Report | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $temp -Encoding UTF8
        Move-Item -LiteralPath $temp -Destination $reportPath -Force
    } catch {
        if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        throw
    }
}

try {
    Start-DevintoshTransaction

    $step++
    Write-DevintoshProgress $step $totalSteps 'Checking runtime and detected hardware inventory'
    if (-not (Test-IsAdministrator)) {
        $EXIT_CODE = $script:EXIT_INSUFFICIENT_PRIVILEGES
        throw 'Administrator privileges are required.'
    }
    if (-not (Test-Path -LiteralPath $hardwarePath -PathType Leaf)) {
        $EXIT_CODE = $script:EXIT_TARGET_NOT_FOUND
        throw "Run configure-opencore-hardware.ps1 first: $hardwarePath"
    }
    Write-DevintoshStepLog $step 'Runtime and live USB hardware inventory are available.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Loading detected USB hardware and profiles'
    $hardware = Get-Content -LiteralPath $hardwarePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $profiles = @(Get-UsbProfiles)
    Write-DevintoshLog 'INFO' "USB capability profiles discovered: $($profiles.Count)."
    Write-DevintoshStepLog $step 'USB profile catalog loaded without manual identity input.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Matching USB controller capability profiles'
    $matched = [System.Collections.Generic.List[object]]::new()
    foreach ($profile in @(Get-ArraySafe $profiles)) {
        if (Test-UsbProfileMatch $hardware $profile) { [void]$matched.Add($profile) }
    }
    $matchedIds = @($matched | ForEach-Object { [string](Get-PropertyValue $_ 'id') } | Select-Object -Unique)
    Write-DevintoshLog 'INFO' "Matched USB profiles: $($matchedIds -join ', ')."
    Write-DevintoshStepLog $step "USB capability matching completed: $($matched.Count) profile(s)." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Resolving USB strategy and validation requirements'
    $strategies = [System.Collections.Generic.List[object]]::new()
    $requiresValidation = $false
    foreach ($profile in @(Get-ArraySafe $matched)) {
        $id = [string](Get-PropertyValue $profile 'id')
        $capabilities = Get-PropertyValue $profile 'capabilities'
        $policy = [string](Get-PropertyValue (Get-PropertyValue $profile 'opencore') 'policy')
        if ($policy -eq 'validation-required') { $requiresValidation = $true }
        $profileRequiresValidation = [bool](Get-PropertyValue $capabilities 'requiresMacOsUsbPortValidation')
        if ($profileRequiresValidation) { $requiresValidation = $true }
        [void]$strategies.Add([pscustomobject]@{
            profileId = $id
            usbController = [string](Get-PropertyValue $capabilities 'usbController')
            requiresMacOsUsbPortValidation = $profileRequiresValidation
            strategy = $(if ($profileRequiresValidation) { 'validation-required' } else { 'profile-declared' })
        })
    }
    Write-DevintoshLog 'INFO' "USB macOS port validation required: $requiresValidation."
    Write-DevintoshStepLog $step 'USB strategy resolved without deriving a macOS port map from Windows.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Applying hardware-agnostic USB safety policy'
    $status = 'NeedsProfile'
    $unresolved = @('usb')
    $warnings = @()
    if ($matched.Count -gt 0) {
        $status = 'NeedsValidation'
        $unresolved = @()
        $warnings += 'USB port mapping is intentionally not generated from Windows PnP data.'
        $warnings += 'Native macOS USB port inventory and an explicitly validated port map are required before USB topology is committed.'
        $warnings += 'XhciPortLimit is not enabled automatically because it is not a substitute for a validated port map.'
        if (-not $requiresValidation) {
            $warnings += 'No explicit USB validation requirement was declared by the matched profiles; review the profile before enabling automatic mutation.'
        }
    }
    if ($matched.Count -gt 1) {
        $warnings += 'Multiple USB capability profiles matched; a future composition stage must resolve precedence explicitly before mutation.'
    }
    Write-DevintoshStepLog $step "USB safety policy completed: $status." $(if ($status -eq 'NeedsProfile') { 'WARN' } else { 'PASS' })

    $step++
    Write-DevintoshProgress $step $totalSteps 'Writing transactional USB resolution report'
    $report = [ordered]@{
        schemaVersion = 1
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        sourceHardware = 'build/opencore/hardware-detected.json'
        sourceProfiles = 'config/hardware/usb'
        status = $status
        matchedProfiles = @($matchedIds)
        strategies = @($strategies)
        applied = $false
        unresolvedCapabilities = @($unresolved)
        warnings = @($warnings)
        intentionallyNotGenerated = @(
            'USB port map',
            'USB port limit bypasses',
            'ACPI USB topology patches',
            'USB kext binary selection inferred from Windows drivers'
        )
        generatedArtifacts = @('build/opencore/usb-resolution.json')
    }
    Write-ReportTransactional ([pscustomobject]$report)
    Write-DevintoshStepLog $step 'USB resolution report written transactionally.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Finalizing hardware-agnostic USB resolution'
    Write-DevintoshLog 'INFO' 'No USB port map or USB topology change was written to config.plist.'
    Complete-DevintoshTransaction
    Complete-DevintoshProgress 'USB resolution complete'
    $EXIT_CODE = $script:EXIT_SUCCESS
} catch {
    Write-DevintoshLog 'ERROR' "USB resolution failed: $($_.Exception.Message)"
    try {
        $ok = Invoke-DevintoshRollback
        if (-not $ok) { $EXIT_CODE = $script:EXIT_ROLLBACK_FAILURE }
    } catch {
        $EXIT_CODE = $script:EXIT_ROLLBACK_FAILURE
    }
    if ($EXIT_CODE -eq $script:EXIT_SUCCESS) { $EXIT_CODE = $script:EXIT_GENERAL_FAILURE }
}

exit $EXIT_CODE
