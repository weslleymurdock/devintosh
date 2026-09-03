#requires -Version 5.1
<#
.SYNOPSIS
    Resolves GPU capability profiles without modifying OpenCore configuration.
.DESCRIPTION
    Hardware-agnostic GPU stage. Physical GPU identities discovered by the Windows
    hardware inventory are matched only against declarative GPU profiles.

    Virtual display adapters and devices without PCI vendor/device identifiers are
    reported separately and never mapped to a physical GPU profile.

    A matched GPU profile that requires compatibility or spoof validation remains
    NeedsValidation. The resolver never invents DeviceProperties, spoof identities,
    framebuffer data, connector patches, or macOS-specific GPU paths.

.PARAMETER Force
    Replaces an existing generated resolution report after creating a backup.

.EXIT CODES
    0 = GPU resolution completed.
    1 = General failure.
    2 = Validation failure.
    3 = Administrator privileges are required.
    4 = Required configuration or resource was not found.
    5 = Automatic rollback failed.
    6 = External dependency or network failure.
    7 = Asset integrity failure.
    8 = Unsupported configuration.
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
$reportPath = Join-Path $outputRoot 'gpu-resolution.json'
$backupRoot = Join-Path $script:BackupRoot 'gpu'
$profileRoot = Join-Path $script:RepoRoot 'config\hardware\gpu'

function Get-PropertyValue {
    param([AllowNull()][object]$Object,[Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}
function Get-ArraySafe { param([AllowNull()]$Value); if ($null -eq $Value) { return @() }; return @($Value) }
function Test-StringEquals {
    param([AllowNull()]$Actual,[AllowNull()]$Expected)
    if ($null -eq $Actual -or $null -eq $Expected) { return $false }
    return ([string]$Actual).Trim().Equals(([string]$Expected).Trim(),[StringComparison]::OrdinalIgnoreCase)
}
function Test-GpuIdentity {
    param([Parameter(Mandatory)]$Gpu,[AllowNull()]$VendorId,[AllowNull()]$DeviceIds,[AllowNull()]$SubsystemIds)
    $actualVendor = Get-PropertyValue $Gpu 'VendorId'
    $actualDevice = Get-PropertyValue $Gpu 'DeviceId'
    $actualSubsystem = Get-PropertyValue $Gpu 'SubsystemId'
    if ($null -ne $VendorId -and -not (Test-StringEquals $actualVendor $VendorId)) { return $false }
    $devices = @(Get-ArraySafe $DeviceIds | ForEach-Object { ([string]$_).Trim().ToUpperInvariant() })
    if ($devices.Count -gt 0 -and $devices -notcontains ([string]$actualDevice).Trim().ToUpperInvariant()) { return $false }
    $subsystems = @(Get-ArraySafe $SubsystemIds | ForEach-Object { ([string]$_).Trim().ToUpperInvariant() })
    if ($subsystems.Count -gt 0 -and $subsystems -notcontains ([string]$actualSubsystem).Trim().ToUpperInvariant()) { return $false }
    return $true
}
function Test-GpuProfileMatch {
    param([Parameter(Mandatory)]$Gpus,[Parameter(Mandatory)]$Profile)
    $rule = Get-PropertyValue $Profile 'match'
    if ($null -eq $rule) { return $false }
    $vendor = Get-PropertyValue $rule 'gpuVendorId'
    $devices = Get-PropertyValue $rule 'gpuDeviceIds'
    $subsystems = Get-PropertyValue $rule 'gpuSubsystemIds'
    foreach ($gpu in @(Get-ArraySafe $Gpus)) {
        if (Test-GpuIdentity $gpu $vendor $devices $subsystems) { return $true }
    }
    foreach ($alternative in @(Get-ArraySafe (Get-PropertyValue $rule 'anyOf'))) {
        foreach ($gpu in @(Get-ArraySafe $Gpus)) {
            if (Test-GpuIdentity $gpu (Get-PropertyValue $alternative 'gpuVendorId') (Get-PropertyValue $alternative 'gpuDeviceIds') (Get-PropertyValue $alternative 'gpuSubsystemIds')) { return $true }
        }
    }
    return $false
}
function Get-GpuProfiles {
    $result = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $profileRoot -PathType Container)) { return @() }
    foreach ($file in @(Get-ChildItem -LiteralPath $profileRoot -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue)) {
        try {
            $profile = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $id = Get-PropertyValue $profile 'id'; $match = Get-PropertyValue $profile 'match'; $capabilities = Get-PropertyValue $profile 'capabilities'
            if ($null -ne $id -and $null -ne $match -and $null -ne $capabilities -and [bool](Get-PropertyValue $capabilities 'gpu')) { [void]$result.Add($profile) }
        } catch { Write-DevintoshLog 'WARN' "Ignoring invalid GPU profile $($file.FullName): $($_.Exception.Message)" }
    }
    return @($result.ToArray())
}
function Get-PhysicalGpus {
    param([Parameter(Mandatory)]$Hardware)
    $all = @(Get-ArraySafe (Get-PropertyValue $Hardware 'gpu'))
    return @($all | Where-Object {
        $vendor = [string](Get-PropertyValue $_ 'VendorId')
        $device = [string](Get-PropertyValue $_ 'DeviceId')
        $vendor -match '^[0-9A-Fa-f]{4}$' -and $device -match '^[0-9A-Fa-f]{4}$'
    })
}
function Get-VirtualOrUnidentifiedGpus {
    param([Parameter(Mandatory)]$Hardware)
    $all = @(Get-ArraySafe (Get-PropertyValue $Hardware 'gpu'))
    return @($all | Where-Object {
        $vendor = [string](Get-PropertyValue $_ 'VendorId')
        $device = [string](Get-PropertyValue $_ 'DeviceId')
        $vendor -notmatch '^[0-9A-Fa-f]{4}$' -or $device -notmatch '^[0-9A-Fa-f]{4}$'
    })
}
function Get-UnmatchedPhysicalGpus {
    param([Parameter(Mandatory)]$Gpus,[Parameter(Mandatory)][object[]]$Profiles)
    $unmatched = [System.Collections.Generic.List[object]]::new()
    foreach ($gpu in @(Get-ArraySafe $Gpus)) {
        $matched = $false
        foreach ($profile in @(Get-ArraySafe $Profiles)) {
            if (Test-GpuProfileMatch @($gpu) $profile) { $matched = $true; break }
        }
        if (-not $matched) {
            [void]$unmatched.Add([pscustomobject]@{
                name = [string](Get-PropertyValue $gpu 'Name')
                pnpDeviceId = [string](Get-PropertyValue $gpu 'PnpDeviceId')
                vendorId = Get-PropertyValue $gpu 'VendorId'
                deviceId = Get-PropertyValue $gpu 'DeviceId'
                subsystemId = Get-PropertyValue $gpu 'SubsystemId'
                driverVersion = Get-PropertyValue $gpu 'DriverVersion'
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
        if (-not $Force) { $script:EXIT_CODE = $script:EXIT_VALIDATION_FAILURE; throw "GPU resolution report already exists. Use -Force to replace it: $reportPath" }
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff',[Globalization.CultureInfo]::InvariantCulture)
        $backup = Join-Path $backupRoot ("gpu-resolution-{0}.json" -f $stamp)
        Copy-Item -LiteralPath $reportPath -Destination $backup -Force
        Add-DevintoshRollbackAction -Name 'Restore previous GPU resolution report' -Action { Copy-Item -LiteralPath $backup -Destination $reportPath -Force }
    } else {
        Add-DevintoshRollbackAction -Name 'Remove newly created GPU resolution report' -Action { if (Test-Path -LiteralPath $reportPath -PathType Leaf) { Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue } }
    }
    $temp = "$reportPath.tmp"
    try { $Report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temp -Encoding UTF8; Move-Item -LiteralPath $temp -Destination $reportPath -Force }
    catch { if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }; throw }
}
try {
    Start-DevintoshTransaction
    $step++; Write-DevintoshProgress $step $totalSteps 'Checking runtime and detected GPU inventory'
    if (-not (Test-IsAdministrator)) { $EXIT_CODE=$script:EXIT_INSUFFICIENT_PRIVILEGES; throw 'Administrator privileges are required.' }
    if (-not (Test-Path -LiteralPath $hardwarePath -PathType Leaf)) { $EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND; throw "Run configure-opencore-hardware.ps1 first: $hardwarePath" }
    Write-DevintoshStepLog $step 'Runtime and live GPU hardware inventory are available.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Loading detected GPUs and declarative profiles'
    $hardware = Get-Content -LiteralPath $hardwarePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $profiles = @(Get-GpuProfiles)
    $physical = @(Get-PhysicalGpus $hardware)
    $unidentified = @(Get-VirtualOrUnidentifiedGpus $hardware)
    Write-DevintoshLog 'INFO' "GPU profiles discovered: $($profiles.Count). Physical GPUs: $($physical.Count). Unidentified/virtual adapters: $($unidentified.Count)."
    Write-DevintoshStepLog $step 'GPU profile catalog loaded without manual identity input.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Matching physical GPU capability profiles'
    $matched = [System.Collections.Generic.List[object]]::new()
    foreach ($profile in @(Get-ArraySafe $profiles)) { if (Test-GpuProfileMatch $physical $profile) { [void]$matched.Add($profile) } }
    $matchedIds = @($matched | ForEach-Object { [string](Get-PropertyValue $_ 'id') } | Select-Object -Unique)
    $unmatched = @(Get-UnmatchedPhysicalGpus $physical $profiles)
    Write-DevintoshLog 'INFO' "Matched GPU profiles: $($matchedIds -join ', ')."
    Write-DevintoshLog 'INFO' "Unmatched physical GPUs: $($unmatched.Count)."
    Write-DevintoshStepLog $step "GPU capability matching completed: $($matched.Count) profile(s)." 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Resolving GPU compatibility and validation requirements'
    $strategies = [System.Collections.Generic.List[object]]::new()
    $requiresValidation = $false
    foreach ($profile in @(Get-ArraySafe $matched)) {
        $id=[string](Get-PropertyValue $profile 'id'); $cap=Get-PropertyValue $profile 'capabilities'; $oc=Get-PropertyValue $profile 'opencore'; $policy=[string](Get-PropertyValue $oc 'policy')
        $spoof=[bool](Get-PropertyValue $cap 'requiresGpuSpoofValidation'); $compat=[bool](Get-PropertyValue $cap 'requiresGpuCompatibilityValidation'); $weg=[bool](Get-PropertyValue $cap 'requiresWhateverGreen')
        if ($policy -eq 'validation-required' -or $spoof -or $compat) { $requiresValidation=$true }
        [void]$strategies.Add([pscustomobject]@{
            profileId=$id
            gpuArchitecture=[string](Get-PropertyValue $cap 'gpuArchitecture')
            requiresWhateverGreen=$weg
            nativeMetal=$([string](Get-PropertyValue $cap 'nativeMetal'))
            requiresGpuCompatibilityValidation=$compat
            requiresGpuSpoofValidation=$spoof
            spoofingPolicy=[string](Get-PropertyValue $cap 'spoofingPolicy')
            policy=$policy
            reason=[string](Get-PropertyValue $oc 'reason')
        })
    }
    Write-DevintoshLog 'INFO' "GPU compatibility validation required: $requiresValidation."
    Write-DevintoshStepLog $step 'GPU strategy resolved without inventing spoofing or device properties.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Applying hardware-agnostic GPU safety policy'
    $status='NeedsProfile'; $unresolved=@('gpu'); $warnings=[System.Collections.Generic.List[string]]::new()
    if ($matched.Count -gt 0) {
        $status='NeedsValidation'; $unresolved=@()
        [void]$warnings.Add('GPU compatibility is not inferred solely from a Windows PCI identity.')
        [void]$warnings.Add('Any GPU spoofing, DeviceProperties, framebuffer or connector configuration requires explicit macOS-side validation.')
        if ($requiresValidation) { [void]$warnings.Add('One or more matched GPU profiles explicitly require validation before configuration mutation.') }
    }
    if ($physical.Count -eq 0) { $status='NeedsProfile'; $unresolved=@('gpu'); [void]$warnings.Add('No physical PCI GPU with a usable vendor/device identity was detected.') }
    if ($unmatched.Count -gt 0) { [void]$warnings.Add('One or more physical GPUs have no matching capability profile; they remain unresolved and are not guessed into another profile.') }
    if ($unidentified.Count -gt 0) { [void]$warnings.Add('Virtual or unidentified display adapters are excluded from physical GPU profile matching.') }
    if ($matched.Count -gt 1) { [void]$warnings.Add('Multiple GPU capability profiles matched; a future composition stage must resolve precedence explicitly before mutation.') }
    Write-DevintoshStepLog $step "GPU safety policy completed: $status." $(if ($status -eq 'NeedsProfile') { 'WARN' } else { 'PASS' })

    $step++; Write-DevintoshProgress $step $totalSteps 'Writing transactional GPU resolution report'
    $physicalReport=@($physical | ForEach-Object { [pscustomobject]@{ name=[string](Get-PropertyValue $_ 'Name'); pnpDeviceId=[string](Get-PropertyValue $_ 'PnpDeviceId'); vendorId=Get-PropertyValue $_ 'VendorId'; deviceId=Get-PropertyValue $_ 'DeviceId'; subsystemId=Get-PropertyValue $_ 'SubsystemId'; driverVersion=Get-PropertyValue $_ 'DriverVersion'; adapterRam=Get-PropertyValue $_ 'AdapterRam' } })
    $virtualReport=@($unidentified | ForEach-Object { [pscustomobject]@{ name=[string](Get-PropertyValue $_ 'Name'); pnpDeviceId=[string](Get-PropertyValue $_ 'PnpDeviceId'); vendorId=Get-PropertyValue $_ 'VendorId'; deviceId=Get-PropertyValue $_ 'DeviceId' } })
    $report=[ordered]@{
        schemaVersion=1
        generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        sourceHardware='build/opencore/hardware-detected.json'
        sourceProfiles='config/hardware/gpu'
        status=$status
        physicalGpus=$physicalReport
        virtualOrUnidentifiedAdapters=$virtualReport
        matchedProfiles=@($matchedIds)
        strategies=@($strategies)
        unmatchedPhysicalGpus=@($unmatched)
        applied=$false
        unresolvedCapabilities=@($unresolved)
        warnings=@($warnings)
        intentionallyNotGenerated=@(
            'GPU spoof identities',
            'GPU DeviceProperties',
            'framebuffer patches',
            'connector or BusID patches',
            'GPU ACPI patches',
            'macOS GPU compatibility claims derived only from Windows driver versions'
        )
        generatedArtifacts=@('build/opencore/gpu-resolution.json')
    }
    Write-ReportTransactional ([pscustomobject]$report)
    Write-DevintoshStepLog $step 'GPU resolution report written transactionally.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Finalizing hardware-agnostic GPU resolution'
    Write-DevintoshLog 'INFO' 'No GPU spoof, DeviceProperties, framebuffer, connector, or config.plist mutation was performed by this stage.'
    Complete-DevintoshTransaction
    Complete-DevintoshProgress 'GPU resolution complete'
    $EXIT_CODE=$script:EXIT_SUCCESS
} catch {
    Write-DevintoshLog 'ERROR' "GPU resolution failed: $($_.Exception.Message)"
    try { $ok=Invoke-DevintoshRollback; if (-not $ok) { $EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE } } catch { $EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE }
    if ($EXIT_CODE -eq $script:EXIT_SUCCESS) { $EXIT_CODE=$script:EXIT_GENERAL_FAILURE }
}
exit $EXIT_CODE
