#requires -Version 5.1
<#
.SYNOPSIS
    Resolves audio capability profiles without modifying OpenCore configuration.
.DESCRIPTION
    Hardware-agnostic audio stage. Windows audio PnP identities are used only to
    select declarative profiles. Generic Windows audio endpoints, streaming devices,
    Bluetooth endpoints and other devices without PCI/HDA identities remain unresolved.

    A matched codec profile that requires AppleALC/layout validation remains
    NeedsValidation. The resolver never guesses layout-id, alcid, DeviceProperties,
    ACPI patches, audio routing, or transport-specific configuration.
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
$reportPath = Join-Path $outputRoot 'audio-resolution.json'
$backupRoot = Join-Path $script:BackupRoot 'audio'
$profileRoot = Join-Path $script:RepoRoot 'config\hardware\audio'

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

function Test-AudioProfileMatch {
    param([Parameter(Mandatory)]$Hardware,[Parameter(Mandatory)]$Profile)
    $rule = Get-PropertyValue $Profile 'match'
    if ($null -eq $rule) { return $false }

    $devices = Get-PropertyValue $Hardware 'audio'
    $vendorId = Get-PropertyValue $rule 'audioVendorId'
    $deviceIds = Get-PropertyValue $rule 'audioDeviceIds'
    $subsystemIds = Get-PropertyValue $rule 'audioSubsystemIds'
    if ($null -ne $vendorId -or $null -ne $deviceIds -or $null -ne $subsystemIds) {
        return Test-CollectionIdentity $devices $vendorId $deviceIds $subsystemIds
    }

    $anyOf = @(Get-ArraySafe (Get-PropertyValue $rule 'anyOf'))
    foreach ($alternative in $anyOf) {
        if (Test-CollectionIdentity $devices (Get-PropertyValue $alternative 'audioVendorId') (Get-PropertyValue $alternative 'audioDeviceIds') (Get-PropertyValue $alternative 'audioSubsystemIds')) {
            return $true
        }
    }
    return $false
}

function Get-AudioProfiles {
    $result = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $profileRoot -PathType Container)) { return @() }

    foreach ($file in @(Get-ChildItem -LiteralPath $profileRoot -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue)) {
        try {
            $profile = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $id = Get-PropertyValue $profile 'id'
            $match = Get-PropertyValue $profile 'match'
            $capabilities = Get-PropertyValue $profile 'capabilities'
            if ($null -ne $id -and $null -ne $match -and $null -ne $capabilities -and [bool](Get-PropertyValue $capabilities 'audio')) {
                [void]$result.Add($profile)
            }
        } catch {
            Write-DevintoshLog 'WARN' "Ignoring invalid audio profile $($file.FullName): $($_.Exception.Message)"
        }
    }
    return @($result.ToArray())
}

function Get-UnmatchedAudioDevices {
    param([Parameter(Mandatory)]$Hardware,[AllowNull()][object[]]$MatchedProfiles)
    $devices = @(Get-ArraySafe (Get-PropertyValue $Hardware 'audio'))
    if ($devices.Count -eq 0) { return @() }

    $profiles = @(Get-ArraySafe $MatchedProfiles)
    $unmatched = [System.Collections.Generic.List[object]]::new()
    foreach ($device in $devices) {
        $vendorId = Get-PropertyValue $device 'VendorId'
        $deviceId = Get-PropertyValue $device 'DeviceId'
        $subsystemId = Get-PropertyValue $device 'SubsystemId'
        $matched = $false

        foreach ($profile in $profiles) {
            $rule = Get-PropertyValue $profile 'match'
            if (Test-CollectionIdentity @($device) (Get-PropertyValue $rule 'audioVendorId') (Get-PropertyValue $rule 'audioDeviceIds') (Get-PropertyValue $rule 'audioSubsystemIds')) {
                $matched = $true
                break
            }
        }

        if (-not $matched) {
            [void]$unmatched.Add([pscustomobject]@{
                name = [string](Get-PropertyValue $device 'Name')
                pnpDeviceId = [string](Get-PropertyValue $device 'PnpDeviceId')
                vendorId = $vendorId
                deviceId = $deviceId
                subsystemId = $subsystemId
                manufacturer = [string](Get-PropertyValue $device 'Manufacturer')
                service = [string](Get-PropertyValue $device 'Service')
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
        if (-not $Force) { throw "Audio resolution report already exists. Use -Force to replace it: $reportPath" }
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff',[Globalization.CultureInfo]::InvariantCulture)
        $backup = Join-Path $backupRoot ("audio-resolution-{0}.json" -f $stamp)
        Copy-Item -LiteralPath $reportPath -Destination $backup -Force
        Add-DevintoshRollbackAction -Name 'Restore previous audio resolution report' -Action {
            Copy-Item -LiteralPath $backup -Destination $reportPath -Force
        }
    } else {
        Add-DevintoshRollbackAction -Name 'Remove newly created audio resolution report' -Action {
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
    Write-DevintoshProgress $step $totalSteps 'Checking runtime and detected audio inventory'
    if (-not (Test-IsAdministrator)) {
        $EXIT_CODE = $script:EXIT_INSUFFICIENT_PRIVILEGES
        throw 'Administrator privileges are required.'
    }
    if (-not (Test-Path -LiteralPath $hardwarePath -PathType Leaf)) {
        $EXIT_CODE = $script:EXIT_TARGET_NOT_FOUND
        throw "Run configure-opencore-hardware.ps1 first: $hardwarePath"
    }
    Write-DevintoshStepLog $step 'Runtime and live audio hardware inventory are available.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Loading detected audio hardware and profiles'
    $hardware = Get-Content -LiteralPath $hardwarePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $profiles = @(Get-AudioProfiles)
    Write-DevintoshLog 'INFO' "Audio capability profiles discovered: $($profiles.Count)."
    Write-DevintoshStepLog $step 'Audio profile catalog loaded without manual identity input.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Matching audio codec capability profiles'
    $matched = [System.Collections.Generic.List[object]]::new()
    foreach ($profile in @(Get-ArraySafe $profiles)) {
        if (Test-AudioProfileMatch $hardware $profile) { [void]$matched.Add($profile) }
    }
    $matchedIds = @($matched | ForEach-Object { [string](Get-PropertyValue $_ 'id') } | Select-Object -Unique)
    $unmatchedDevices = @(Get-UnmatchedAudioDevices $hardware $matched.ToArray())
    Write-DevintoshLog 'INFO' "Matched audio profiles: $($matchedIds -join ', ')."
    Write-DevintoshLog 'INFO' "Unmatched audio devices/endpoints: $($unmatchedDevices.Count)."
    Write-DevintoshStepLog $step "Audio capability matching completed: $($matched.Count) profile(s)." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Resolving native audio and fallback strategy'
    $strategies = [System.Collections.Generic.List[object]]::new()
    $requiresValidation = $false
    $fallbackAvailable = $false
    foreach ($profile in @(Get-ArraySafe $matched)) {
        $id = [string](Get-PropertyValue $profile 'id')
        $capabilities = Get-PropertyValue $profile 'capabilities'
        $opencore = Get-PropertyValue $profile 'opencore'
        $policy = [string](Get-PropertyValue $opencore 'policy')
        $audio = Get-PropertyValue $opencore 'audio'
        $strategy = [string](Get-PropertyValue $audio 'strategy')
        $profileRequiresValidation = [bool](Get-PropertyValue $capabilities 'requiresAudioLayoutValidation')
        if ($policy -eq 'validation-required' -or $profileRequiresValidation) { $requiresValidation = $true }
        [void]$strategies.Add([pscustomobject]@{
            profileId = $id
            codec = [string](Get-PropertyValue $capabilities 'codec')
            requiresAppleAlc = [bool](Get-PropertyValue $capabilities 'requiresAppleAlc')
            requiresAudioLayoutValidation = $profileRequiresValidation
            strategy = $(if ([string]::IsNullOrWhiteSpace($strategy)) { 'validation-required' } else { $strategy })
            validation = $(if ($profileRequiresValidation -or $policy -eq 'validation-required') { 'required' } else { 'not-declared' })
        })

        $fallback = Get-PropertyValue $audio 'fallback'
        if ($null -ne $fallback -and [bool](Get-PropertyValue $fallback 'available')) { $fallbackAvailable = $true }
    }

    $fallbackProfiles = @(Get-ArraySafe $profiles | Where-Object {
        $cap = Get-PropertyValue $_ 'capabilities'
        $oc = Get-PropertyValue $_ 'opencore'
        $fallback = Get-PropertyValue $oc 'audioFallback'
        $null -ne $fallback -and [bool](Get-PropertyValue $cap 'audio')
    } | ForEach-Object { [string](Get-PropertyValue $_ 'id') })

    Write-DevintoshLog 'INFO' "Native audio validation required: $requiresValidation."
    Write-DevintoshLog 'INFO' "Declarative alternative audio transport profiles available: $($fallbackProfiles.Count)."
    Write-DevintoshStepLog $step 'Audio strategy resolved; native layout and fallback activation remain validation-gated.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Applying hardware-agnostic audio safety policy'
    $status = 'NeedsProfile'
    $unresolved = @('audio')
    $warnings = [System.Collections.Generic.List[string]]::new()
    if ($matched.Count -gt 0) {
        $status = 'NeedsValidation'
        $unresolved = @()
        [void]$warnings.Add('Audio layout selection is intentionally not inferred from Windows codec identity alone.')
        [void]$warnings.Add('Native macOS codec validation and an explicitly validated layout-id are required before native audio configuration is committed.')
    }
    if ($fallbackProfiles.Count -gt 0) {
        [void]$warnings.Add('Alternative audio transport is a capability-level fallback; it is not activated merely because a Windows endpoint exists.')
    } else {
        [void]$warnings.Add('No validated alternative audio transport profile is currently declared; unknown transports remain unresolved.')
    }
    if ($unmatchedDevices.Count -gt 0) {
        [void]$warnings.Add('One or more detected audio devices/endpoints have no matching capability profile; they remain unresolved and are not guessed into another profile.')
    }
    if ($matched.Count -gt 1) {
        [void]$warnings.Add('Multiple audio capability profiles matched; a future composition stage must resolve precedence explicitly before mutation.')
    }
    Write-DevintoshStepLog $step "Audio safety policy completed: $status." $(if ($status -eq 'NeedsProfile') { 'WARN' } else { 'PASS' })

    $step++
    Write-DevintoshProgress $step $totalSteps 'Writing transactional audio resolution report'
    $report = [ordered]@{
        schemaVersion = 1
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        sourceHardware = 'build/opencore/hardware-detected.json'
        sourceProfiles = 'config/hardware/audio'
        status = $status
        matchedProfiles = @($matchedIds)
        strategies = @($strategies)
        unmatchedDevices = @($unmatchedDevices)
        alternativeAudioTransportProfiles = @($fallbackProfiles)
        alternativeAudioTransportAvailable = $fallbackProfiles.Count -gt 0
        applied = $false
        unresolvedCapabilities = @($unresolved)
        warnings = @($warnings)
        intentionallyNotGenerated = @(
            'AppleALC layout-id',
            'alcid boot-arg',
            'Audio DeviceProperties',
            'Audio ACPI patches',
            'Audio routing or transport configuration',
            'Audio kext binaries from Windows driver versions'
        )
        generatedArtifacts = @('build/opencore/audio-resolution.json')
    }
    Write-ReportTransactional ([pscustomobject]$report)
    Write-DevintoshStepLog $step 'Audio resolution report written transactionally.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Finalizing hardware-agnostic audio resolution'
    Write-DevintoshLog 'INFO' 'No audio kext binary, layout-id, fallback transport, or config.plist mutation was performed by this stage.'
    Complete-DevintoshTransaction
    Complete-DevintoshProgress 'Audio resolution complete'
    $EXIT_CODE = $script:EXIT_SUCCESS
} catch {
    Write-DevintoshLog 'ERROR' "Audio resolution failed: $($_.Exception.Message)"
    try {
        $ok = Invoke-DevintoshRollback
        if (-not $ok) { $EXIT_CODE = $script:EXIT_ROLLBACK_FAILURE }
    } catch {
        $EXIT_CODE = $script:EXIT_ROLLBACK_FAILURE
    }
    if ($EXIT_CODE -eq $script:EXIT_SUCCESS) { $EXIT_CODE = $script:EXIT_GENERAL_FAILURE }
}

exit $EXIT_CODE
