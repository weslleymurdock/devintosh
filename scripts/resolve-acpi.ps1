#requires -Version 5.1
<#
.SYNOPSIS
    Resolves ACPI capability profiles without generating ACPI tables or patches.
.DESCRIPTION
    Hardware-agnostic ACPI stage. Windows hardware inventory is used only to select
    declarative capability profiles. ACPI additions, deletions, patches and SSDT/DSDT
    contents are never inferred from Windows PnP names or device identifiers.

    The stage produces a transactional resolution report. A later validation stage may
    consume native macOS ACPI table evidence and an explicitly validated profile.
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
$reportPath = Join-Path $outputRoot 'acpi-resolution.json'
$backupRoot = Join-Path $script:BackupRoot 'acpi'
$profileRoot = Join-Path $script:RepoRoot 'config\hardware\acpi'

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

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required JSON file not found: $Path" }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Test-AcpiProfileMatch {
    param([Parameter(Mandatory)]$Hardware,[Parameter(Mandatory)]$Profile)
    $rule = Get-PropertyValue $Profile 'match'
    if ($null -eq $rule) { return $false }

    $cpu = Get-PropertyValue $Hardware 'cpu'
    $platform = Get-PropertyValue $Hardware 'platform'

    $expected = Get-PropertyValue $rule 'cpuVendor'
    if ($null -ne $expected -and -not (Test-StringEquals (Get-PropertyValue $cpu 'Manufacturer') $expected)) { return $false }

    $expected = Get-PropertyValue $rule 'cpuName'
    if ($null -ne $expected -and -not (Test-StringEquals (Get-PropertyValue $cpu 'Name') $expected)) { return $false }

    $regex = Get-PropertyValue $rule 'cpuNameRegex'
    if ($null -ne $regex -and [string](Get-PropertyValue $cpu 'Name') -notmatch [string]$regex) { return $false }

    $expected = Get-PropertyValue $rule 'platformManufacturer'
    if ($null -ne $expected -and -not (Test-StringEquals (Get-PropertyValue $platform 'Manufacturer') $expected)) { return $false }

    $expected = Get-PropertyValue $rule 'platformModel'
    if ($null -ne $expected -and -not (Test-StringEquals (Get-PropertyValue $platform 'Model') $expected)) { return $false }

    $regex = Get-PropertyValue $rule 'platformModelRegex'
    if ($null -ne $regex -and [string](Get-PropertyValue $platform 'Model') -notmatch [string]$regex) { return $false }

    $minimum = Get-PropertyValue $rule 'cpuCoresMin'
    if ($null -ne $minimum -and [int](Get-PropertyValue $cpu 'Cores') -lt [int]$minimum) { return $false }

    $minimum = Get-PropertyValue $rule 'cpuThreadsMin'
    if ($null -ne $minimum -and [int](Get-PropertyValue $cpu 'Threads') -lt [int]$minimum) { return $false }

    return $true
}

function Get-AcpiProfiles {
    $result = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $profileRoot -PathType Container)) { return @() }

    foreach ($file in @(Get-ChildItem -LiteralPath $profileRoot -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue)) {
        try {
            $profile = Read-JsonFile $file.FullName
            $id = Get-PropertyValue $profile 'id'
            $match = Get-PropertyValue $profile 'match'
            $capabilities = Get-PropertyValue $profile 'capabilities'
            if ($null -ne $id -and $null -ne $match -and $null -ne $capabilities -and [bool](Get-PropertyValue $capabilities 'acpi')) {
                [void]$result.Add($profile)
            }
        } catch {
            Write-DevintoshLog 'WARN' "Ignoring invalid ACPI profile $($file.FullName): $($_.Exception.Message)"
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
        $backup = Join-Path $backupRoot ("acpi-resolution-{0}.json" -f $stamp)
        Copy-Item -LiteralPath $reportPath -Destination $backup -Force
        Add-DevintoshRollbackAction -Name 'Restore previous ACPI resolution report' -Action {
            Copy-Item -LiteralPath $backup -Destination $reportPath -Force
        }
    } else {
        Add-DevintoshRollbackAction -Name 'Remove newly created ACPI resolution report' -Action {
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
    Write-DevintoshStepLog $step 'Runtime and live hardware inventory are available.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Loading detected hardware and ACPI profiles'
    $hardware = Read-JsonFile $hardwarePath
    $profiles = @(Get-AcpiProfiles)
    Write-DevintoshLog 'INFO' "ACPI capability profiles discovered: $($profiles.Count)."
    Write-DevintoshStepLog $step 'ACPI profile catalog loaded without manual identity input.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Matching ACPI capability profiles'
    $matched = [System.Collections.Generic.List[object]]::new()
    foreach ($profile in @(Get-ArraySafe $profiles)) {
        if (Test-AcpiProfileMatch $hardware $profile) { [void]$matched.Add($profile) }
    }
    $matchedIds = @($matched | ForEach-Object { [string](Get-PropertyValue $_ 'id') } | Select-Object -Unique)
    Write-DevintoshLog 'INFO' "Matched ACPI profiles: $($matchedIds -join ', ')."
    Write-DevintoshStepLog $step "ACPI capability matching completed: $($matched.Count) profile(s)." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Resolving ACPI strategy and validation requirements'
    $strategies = [System.Collections.Generic.List[object]]::new()
    $requiresValidation = $false
    foreach ($profile in @(Get-ArraySafe $matched)) {
        $id = [string](Get-PropertyValue $profile 'id')
        $openCore = Get-PropertyValue $profile 'opencore'
        $acpi = Get-PropertyValue $openCore 'acpi'
        $policy = [string](Get-PropertyValue $openCore 'policy')
        if ($policy -eq 'validation-required') { $requiresValidation = $true }
        if ($null -ne $acpi) {
            $strategy = [string](Get-PropertyValue $acpi 'strategy')
            $evidence = @(Get-ArraySafe (Get-PropertyValue $acpi 'requiredEvidence'))
            $prohibited = @(Get-ArraySafe (Get-PropertyValue $acpi 'prohibitedAutomation'))
            if ($strategy -eq 'validation-required') { $requiresValidation = $true }
            [void]$strategies.Add([pscustomobject]@{
                profileId = $id
                strategy = $strategy
                requiredEvidence = $evidence
                prohibitedAutomation = $prohibited
            })
        }
    }
    Write-DevintoshLog 'INFO' "ACPI validation required: $requiresValidation."
    Write-DevintoshStepLog $step 'ACPI strategy resolved without fabricating tables or patches.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Applying hardware-agnostic ACPI safety policy'
    $status = 'NeedsProfile'
    $unresolved = @('acpi')
    $warnings = @()
    if ($matched.Count -gt 0) {
        $status = 'NeedsValidation'
        $unresolved = @()
        $warnings += 'ACPI configuration is intentionally not generated from Windows PnP data.'
        $warnings += 'Native macOS ACPI table evidence is required before adding, deleting or patching ACPI tables.'
        if (-not $requiresValidation) {
            $warnings += 'No explicit ACPI validation requirement was declared by the matched profiles; review the profile before enabling automatic mutation.'
        }
    }
    if ($matched.Count -gt 1) {
        $warnings += 'Multiple ACPI capability profiles matched; a future composition stage must resolve precedence explicitly before mutation.'
    }
    Write-DevintoshStepLog $step "ACPI safety policy completed: $status." $(if ($status -eq 'NeedsProfile') { 'WARN' } else { 'PASS' })

    $step++
    Write-DevintoshProgress $step $totalSteps 'Writing transactional ACPI resolution report'
    $report = [ordered]@{
        schemaVersion = 1
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        sourceHardware = 'build/opencore/hardware-detected.json'
        sourceProfiles = 'config/hardware/acpi'
        status = $status
        matchedProfiles = @($matchedIds)
        strategies = @($strategies)
        applied = $false
        unresolvedCapabilities = @($unresolved)
        warnings = @($warnings)
        intentionallyNotGenerated = @(
            'ACPI Add entries',
            'ACPI Delete entries',
            'ACPI binary patches',
            'DSDT/SSDT binaries',
            'ACPI table contents inferred from Windows PnP data'
        )
        generatedArtifacts = @('build/opencore/acpi-resolution.json')
    }
    Write-ReportTransactional ([pscustomobject]$report)
    Write-DevintoshStepLog $step 'ACPI resolution report written transactionally.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Finalizing hardware-agnostic ACPI resolution'
    Write-DevintoshLog 'INFO' 'No ACPI table, SSDT, DSDT or patch was written to config.plist.'
    Complete-DevintoshTransaction
    Complete-DevintoshProgress 'ACPI resolution complete'
    $EXIT_CODE = $script:EXIT_SUCCESS
} catch {
    Write-DevintoshLog 'ERROR' "ACPI resolution failed: $($_.Exception.Message)"
    try {
        $ok = Invoke-DevintoshRollback
        if (-not $ok) { $EXIT_CODE = $script:EXIT_ROLLBACK_FAILURE }
    } catch {
        $EXIT_CODE = $script:EXIT_ROLLBACK_FAILURE
    }
    if ($EXIT_CODE -eq $script:EXIT_SUCCESS) { $EXIT_CODE = $script:EXIT_GENERAL_FAILURE }
}

exit $EXIT_CODE
