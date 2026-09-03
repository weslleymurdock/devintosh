#requires -Version 5.1
<#
.SYNOPSIS
    Resolves network controller capability profiles without modifying OpenCore configuration.
.DESCRIPTION
    Hardware-agnostic network stage. Windows network identities are used only to select
    declarative profiles. Kext acquisition and Kernel->Add composition remain separate
    pipeline stages.

    A matched controller that requires a profile-managed Ethernet kext remains
    NeedsValidation until the resulting macOS networking path has been validated.
    Unknown controllers remain NeedsProfile and are never guessed into another profile.
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
$reportPath = Join-Path $outputRoot 'network-resolution.json'
$backupRoot = Join-Path $script:BackupRoot 'network'
$profileRoot = Join-Path $script:RepoRoot 'config\hardware\network'

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

function Test-NetworkProfileMatch {
    param([Parameter(Mandatory)]$Hardware,[Parameter(Mandatory)]$Profile)
    $rule = Get-PropertyValue $Profile 'match'
    if ($null -eq $rule) { return $false }

    $network = Get-PropertyValue $Hardware 'network'
    if ($null -eq $network) { return $false }
    $devices = Get-PropertyValue $network 'pnp'

    $vendorId = Get-PropertyValue $rule 'networkVendorId'
    $deviceIds = Get-PropertyValue $rule 'networkDeviceIds'
    $subsystemIds = Get-PropertyValue $rule 'networkSubsystemIds'
    if ($null -ne $vendorId -or $null -ne $deviceIds -or $null -ne $subsystemIds) {
        return Test-CollectionIdentity $devices $vendorId $deviceIds $subsystemIds
    }

    $anyOf = @(Get-ArraySafe (Get-PropertyValue $rule 'anyOf'))
    foreach ($alternative in $anyOf) {
        if (Test-CollectionIdentity $devices (Get-PropertyValue $alternative 'networkVendorId') (Get-PropertyValue $alternative 'networkDeviceIds') (Get-PropertyValue $alternative 'networkSubsystemIds')) {
            return $true
        }
    }
    return $false
}

function Get-NetworkProfiles {
    $result = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $profileRoot -PathType Container)) { return @() }

    foreach ($file in @(Get-ChildItem -LiteralPath $profileRoot -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue)) {
        try {
            $profile = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $id = Get-PropertyValue $profile 'id'
            $match = Get-PropertyValue $profile 'match'
            $capabilities = Get-PropertyValue $profile 'capabilities'
            if ($null -ne $id -and $null -ne $match -and $null -ne $capabilities -and [bool](Get-PropertyValue $capabilities 'network')) {
                [void]$result.Add($profile)
            }
        } catch {
            Write-DevintoshLog 'WARN' "Ignoring invalid network profile $($file.FullName): $($_.Exception.Message)"
        }
    }
    return @($result.ToArray())
}

function Get-UnmatchedNetworkAdapters {
    param([Parameter(Mandatory)]$Hardware,[Parameter(Mandatory)][object[]]$MatchedProfiles)
    $network = Get-PropertyValue $Hardware 'network'
    $devices = @(Get-ArraySafe (Get-PropertyValue $network 'pnp'))
    if ($devices.Count -eq 0) { return @() }

    $unmatched = [System.Collections.Generic.List[object]]::new()
    foreach ($device in $devices) {
        $matched = $false
        foreach ($profile in @(Get-ArraySafe $MatchedProfiles)) {
            if (Test-CollectionIdentity @($device) (Get-PropertyValue (Get-PropertyValue $profile 'match') 'networkVendorId') (Get-PropertyValue (Get-PropertyValue $profile 'match') 'networkDeviceIds') (Get-PropertyValue (Get-PropertyValue $profile 'match') 'networkSubsystemIds')) {
                $matched = $true
                break
            }
        }
        if (-not $matched) {
            [void]$unmatched.Add([pscustomobject]@{
                name = [string](Get-PropertyValue $device 'Name')
                pnpDeviceId = [string](Get-PropertyValue $device 'PnpDeviceId')
                vendorId = Get-PropertyValue $device 'VendorId'
                deviceId = Get-PropertyValue $device 'DeviceId'
                subsystemId = Get-PropertyValue $device 'SubsystemId'
            })
        }
    }
    return @($unmatched.ToArray())
}

function Write-ReportTransactional {
    param([Parameter(Mandatory)]$Report)
    if (-not (Test-Path -LiteralPath $outputRoot -PathType Container)) { [void](New-Item -ItemType Directory -Path $outputRoot -Force) }
    if (-not (Test-Path -LiteralPath $backupRoot -PathType Container)) { [void](New-Item -ItemType Directory -Path $backupRoot -Force) }

    if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff',[Globalization.CultureInfo]::InvariantCulture)
        $backup = Join-Path $backupRoot ("network-resolution-{0}.json" -f $stamp)
        Copy-Item -LiteralPath $reportPath -Destination $backup -Force
        Add-DevintoshRollbackAction -Name 'Restore previous network resolution report' -Action {
            Copy-Item -LiteralPath $backup -Destination $reportPath -Force
        }
    } else {
        Add-DevintoshRollbackAction -Name 'Remove newly created network resolution report' -Action {
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
    Write-DevintoshProgress $step $totalSteps 'Checking runtime and detected network inventory'
    if (-not (Test-IsAdministrator)) {
        $EXIT_CODE = $script:EXIT_INSUFFICIENT_PRIVILEGES
        throw 'Administrator privileges are required.'
    }
    if (-not (Test-Path -LiteralPath $hardwarePath -PathType Leaf)) {
        $EXIT_CODE = $script:EXIT_TARGET_NOT_FOUND
        throw "Run configure-opencore-hardware.ps1 first: $hardwarePath"
    }
    Write-DevintoshStepLog $step 'Runtime and live network hardware inventory are available.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Loading detected network hardware and profiles'
    $hardware = Get-Content -LiteralPath $hardwarePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $profiles = @(Get-NetworkProfiles)
    Write-DevintoshLog 'INFO' "Network capability profiles discovered: $($profiles.Count)."
    Write-DevintoshStepLog $step 'Network profile catalog loaded without manual identity input.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Matching network controller capability profiles'
    $matched = [System.Collections.Generic.List[object]]::new()
    foreach ($profile in @(Get-ArraySafe $profiles)) {
        if (Test-NetworkProfileMatch $hardware $profile) { [void]$matched.Add($profile) }
    }
    $matchedIds = @($matched | ForEach-Object { [string](Get-PropertyValue $_ 'id') } | Select-Object -Unique)
    $unmatchedAdapters = @(Get-UnmatchedNetworkAdapters $hardware $matched.ToArray())
    Write-DevintoshLog 'INFO' "Matched network profiles: $($matchedIds -join ', ')."
    Write-DevintoshLog 'INFO' "Unmatched network adapters: $($unmatchedAdapters.Count)."
    Write-DevintoshStepLog $step "Network capability matching completed: $($matched.Count) profile(s)." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Resolving network strategy and validation requirements'
    $strategies = [System.Collections.Generic.List[object]]::new()
    $requiresValidation = $false
    foreach ($profile in @(Get-ArraySafe $matched)) {
        $id = [string](Get-PropertyValue $profile 'id')
        $capabilities = Get-PropertyValue $profile 'capabilities'
        $opencore = Get-PropertyValue $profile 'opencore'
        $policy = [string](Get-PropertyValue $opencore 'policy')
        $strategy = [string](Get-PropertyValue $opencore 'kextStrategy')
        $profileRequiresValidation = [bool](Get-PropertyValue $capabilities 'requiresEthernetKext')
        if ($policy -eq 'validation-required' -or $profileRequiresValidation) { $requiresValidation = $true }
        [void]$strategies.Add([pscustomobject]@{
            profileId = $id
            networkController = [string](Get-PropertyValue $capabilities 'networkController')
            requiresEthernetKext = $profileRequiresValidation
            kextStrategy = $(if ([string]::IsNullOrWhiteSpace($strategy)) { 'profile-managed' } else { $strategy })
            validation = $(if ($profileRequiresValidation -or $policy -eq 'validation-required') { 'required' } else { 'not-declared' })
        })
    }
    Write-DevintoshLog 'INFO' "Network macOS validation required: $requiresValidation."
    Write-DevintoshStepLog $step 'Network strategy resolved without selecting binaries from Windows driver versions.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Applying hardware-agnostic network safety policy'
    $status = 'NeedsProfile'
    $unresolved = @('network')
    $warnings = @()
    if ($matched.Count -gt 0) {
        $status = 'NeedsValidation'
        $unresolved = @()
        $warnings += 'Network kext selection remains declarative and is not inferred from Windows driver versions.'
        $warnings += 'A matched Ethernet controller requires macOS-side network validation before the profile is considered fully resolved.'
    }
    if ($unmatchedAdapters.Count -gt 0) {
        $warnings += "One or more detected network adapters have no matching capability profile; they remain unresolved and are not guessed into another profile."
    }
    if ($matched.Count -gt 1) {
        $warnings += 'Multiple network capability profiles matched; a future composition stage must resolve precedence explicitly before mutation.'
    }
    Write-DevintoshStepLog $step "Network safety policy completed: $status." $(if ($status -eq 'NeedsProfile') { 'WARN' } else { 'PASS' })

    $step++
    Write-DevintoshProgress $step $totalSteps 'Writing transactional network resolution report'
    $report = [ordered]@{
        schemaVersion = 1
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        sourceHardware = 'build/opencore/hardware-detected.json'
        sourceProfiles = 'config/hardware/network'
        status = $status
        matchedProfiles = @($matchedIds)
        strategies = @($strategies)
        unmatchedAdapters = @($unmatchedAdapters)
        applied = $false
        unresolvedCapabilities = @($unresolved)
        warnings = @($warnings)
        intentionallyNotGenerated = @(
            'Network kext binaries from Windows driver versions',
            'Kernel->Add entries',
            'Network device properties or spoofing',
            'macOS network interface configuration'
        )
        generatedArtifacts = @('build/opencore/network-resolution.json')
    }
    Write-ReportTransactional ([pscustomobject]$report)
    Write-DevintoshStepLog $step 'Network resolution report written transactionally.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Finalizing hardware-agnostic network resolution'
    Write-DevintoshLog 'INFO' 'No network kext binary or config.plist mutation was performed by this stage.'
    Complete-DevintoshTransaction
    Complete-DevintoshProgress 'Network resolution complete'
    $EXIT_CODE = $script:EXIT_SUCCESS
} catch {
    Write-DevintoshLog 'ERROR' "Network resolution failed: $($_.Exception.Message)"
    try {
        $ok = Invoke-DevintoshRollback
        if (-not $ok) { $EXIT_CODE = $script:EXIT_ROLLBACK_FAILURE }
    } catch {
        $EXIT_CODE = $script:EXIT_ROLLBACK_FAILURE
    }
    if ($EXIT_CODE -eq $script:EXIT_SUCCESS) { $EXIT_CODE = $script:EXIT_GENERAL_FAILURE }
}

exit $EXIT_CODE
