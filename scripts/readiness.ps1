#requires -Version 5.1
<#
.SYNOPSIS
    Evaluates whether the generated Devintosh/OpenCore state is ready for the next stage.
.DESCRIPTION
    Hardware-agnostic readiness gate. It consumes generated resolution/application and
    validation reports from previous stages and produces a single readiness decision.

    This script is report-only: it never changes config.plist, EFI contents, SMBIOS
    identity, ACPI, USB, audio, network or GPU configuration. A missing or stale
    prerequisite is reported conservatively instead of being guessed.

.PARAMETER Force
    Replaces an existing readiness report after creating a rollback backup.

.READINESS STATES
    Ready           All required reports exist, contain acceptable states, and the
                    final OpenCore config was accepted by the pinned ocvalidate.
    NeedsValidation At least one required capability remains validation-required,
                    while no capability is explicitly missing a profile.
    NeedsProfile    At least one required capability has no matching profile.
    Blocked         A required artifact is missing, malformed, or explicitly failed,
                    so the state cannot be evaluated safely.

.EXIT CODES
    0 = Readiness evaluated successfully. The report may still say NeedsValidation,
        NeedsProfile, or Blocked because those are readiness states, not script errors.
    1 = General failure.
    2 = Validation failure.
    3 = Administrator privileges are required.
    4 = Required target/resource was not found.
    5 = Automatic rollback failed.
    6 = External dependency failure.
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
$totalSteps = 8
$outputRoot = Join-Path $script:BuildRoot 'opencore'
$reportPath = Join-Path $outputRoot 'readiness-report.json'
$backupRoot = Join-Path $script:BackupRoot 'readiness'

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
function Read-Report {
    param([Parameter(Mandatory)][string]$RelativePath)
    $path = Join-Path $script:RepoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ path=$RelativePath; exists=$false; valid=$false; data=$null; error='Required report was not found.' }
    }
    try {
        $data = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        return [pscustomobject]@{ path=$RelativePath; exists=$true; valid=$true; data=$data; error=$null }
    } catch {
        return [pscustomobject]@{ path=$RelativePath; exists=$true; valid=$false; data=$null; error=$_.Exception.Message }
    }
}
function Get-ReportStatus {
    param([AllowNull()]$Report)
    if ($null -eq $Report -or -not $Report.valid -or $null -eq $Report.data) { return 'Blocked' }
    $status = Get-PropertyValue $Report.data 'status'
    if ($null -eq $status) { return 'Unknown' }
    return [string]$status
}
function Write-ReportTransactional {
    param([Parameter(Mandatory)]$Report)
    if (-not (Test-Path -LiteralPath $outputRoot -PathType Container)) { [void](New-Item -ItemType Directory -Path $outputRoot -Force) }
    if (-not (Test-Path -LiteralPath $backupRoot -PathType Container)) { [void](New-Item -ItemType Directory -Path $backupRoot -Force) }
    $backup = $null
    if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
        if (-not $Force) {
            $script:EXIT_CODE = $script:EXIT_VALIDATION_FAILURE
            throw "Readiness report already exists. Use -Force to replace it: $reportPath"
        }
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff',[Globalization.CultureInfo]::InvariantCulture)
        $backup = Join-Path $backupRoot ("readiness-report-{0}.json" -f $stamp)
        Copy-Item -LiteralPath $reportPath -Destination $backup -Force
        Add-DevintoshRollbackAction -Name 'Restore previous readiness report' -Action { Copy-Item -LiteralPath $backup -Destination $reportPath -Force }
    } else {
        Add-DevintoshRollbackAction -Name 'Remove newly created readiness report' -Action { if (Test-Path -LiteralPath $reportPath -PathType Leaf) { Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue } }
    }
    $temp = "$reportPath.tmp"
    try {
        $Report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temp -Encoding UTF8
        Move-Item -LiteralPath $temp -Destination $reportPath -Force
    } catch {
        if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        throw
    }
}

try {
    Start-DevintoshTransaction

    $step++; Write-DevintoshProgress $step $totalSteps 'Checking runtime and readiness prerequisites'
    if (-not (Test-IsAdministrator)) { $EXIT_CODE=$script:EXIT_INSUFFICIENT_PRIVILEGES; throw 'Administrator privileges are required.' }
    if (-not (Test-Path -LiteralPath $outputRoot -PathType Container)) { $EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND; throw "OpenCore build state was not found: $outputRoot" }
    Write-DevintoshStepLog $step 'Runtime and OpenCore build state are available.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Loading generated capability and validation reports'
    $reportDefinitions = @(
        [pscustomobject]@{ key='hardware'; path='build/opencore/hardware-detected.json'; required=$true; kind='inventory' },
        [pscustomobject]@{ key='hardwareResolution'; path='build/opencore/configuration-report.json'; required=$true; kind='resolution' },
        [pscustomobject]@{ key='gpu'; path='build/opencore/gpu-resolution.json'; required=$true; kind='resolution' },
        [pscustomobject]@{ key='smbios'; path='build/opencore/smbios-resolution.json'; required=$true; kind='resolution' },
        [pscustomobject]@{ key='acpi'; path='build/opencore/acpi-resolution.json'; required=$true; kind='resolution' },
        [pscustomobject]@{ key='usb'; path='build/opencore/usb-resolution.json'; required=$true; kind='resolution' },
        [pscustomobject]@{ key='network'; path='build/opencore/network-resolution.json'; required=$true; kind='resolution' },
        [pscustomobject]@{ key='audio'; path='build/opencore/audio-resolution.json'; required=$true; kind='resolution' },
        [pscustomobject]@{ key='kextResolution'; path='build/opencore/kext-resolution.json'; required=$true; kind='resolution' },
        [pscustomobject]@{ key='kextAssets'; path='build/opencore/kext-assets.json'; required=$true; kind='assets' },
        [pscustomobject]@{ key='kextComposition'; path='build/opencore/kext-composition-report.json'; required=$true; kind='composition' },
        [pscustomobject]@{ key='validation'; path='build/opencore/validation-report.json'; required=$true; kind='validation' }
    )
    $loaded = [System.Collections.Generic.List[object]]::new()
    foreach ($definition in $reportDefinitions) {
        $item = Read-Report $definition.path
        [void]$loaded.Add([pscustomobject]@{ key=$definition.key; path=$definition.path; required=[bool]$definition.required; kind=$definition.kind; exists=$item.exists; valid=$item.valid; data=$item.data; error=$item.error })
    }
    Write-DevintoshStepLog $step 'All readiness inputs were inspected without modifying generated state.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Checking report integrity and required artifacts'
    $blockedReasons = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($loaded)) {
        if ($item.required -and -not $item.exists) { [void]$blockedReasons.Add("Missing required report: $($item.path)") }
        elseif ($item.required -and -not $item.valid) { [void]$blockedReasons.Add("Malformed required report: $($item.path): $($item.error)") }
    }
    $configPath = Join-Path $script:BuildRoot 'efi\EFI\OC\config.plist'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { [void]$blockedReasons.Add('Generated OpenCore config.plist is missing.') }
    Write-DevintoshStepLog $step "Readiness input integrity checked: $($blockedReasons.Count) blocking issue(s)." $(if($blockedReasons.Count -eq 0){'PASS'}else{'WARN'})

    $step++; Write-DevintoshProgress $step $totalSteps 'Evaluating capability resolution states'
    $resolutionKeys = @('hardwareResolution','gpu','smbios','acpi','usb','network','audio','kextResolution','kextAssets','kextComposition')
    $states = [System.Collections.Generic.List[object]]::new()
    foreach ($key in $resolutionKeys) {
        $item = @($loaded | Where-Object { $_.key -eq $key })[0]
        $status = Get-ReportStatus $item
        $unresolved = @()
        if ($null -ne $item.data) { $unresolved = @(Get-ArraySafe (Get-PropertyValue $item.data 'unresolvedCapabilities')) }
        [void]$states.Add([pscustomobject]@{ key=$key; path=$item.path; status=$status; unresolvedCapabilities=$unresolved })
    }
    $needsProfile = @($states | Where-Object { $_.status -eq 'NeedsProfile' -or @($_.unresolvedCapabilities).Count -gt 0 })
    $needsValidation = @($states | Where-Object { $_.status -eq 'NeedsValidation' })
    $unknownStates = @($states | Where-Object {
        $_.status -notin @('Resolved','Valid','NeedsValidation','NeedsProfile') -and
        -not ($_.key -eq 'kextComposition' -and $_.status -eq 'Applied')
    })
    if ($unknownStates.Count -gt 0) { foreach($state in $unknownStates){ [void]$blockedReasons.Add("Unknown readiness state '$($state.status)' in $($state.path).") } }
    Write-DevintoshLog 'INFO' "Capability states: NeedsProfile=$($needsProfile.Count), NeedsValidation=$($needsValidation.Count), Unknown=$($unknownStates.Count)."
    Write-DevintoshStepLog $step 'Capability state evaluation completed.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Evaluating final OpenCore validation result'
    $validationItem = @($loaded | Where-Object { $_.key -eq 'validation' })[0]
    $validationStatus = Get-ReportStatus $validationItem
    $validatorExit = Get-PropertyValue $validationItem.data 'validatorExitCode'
    $validationVersion = [string](Get-PropertyValue $validationItem.data 'openCoreVersion')
    if ($validationStatus -ne 'Valid' -or $null -eq $validatorExit -or [int]$validatorExit -ne 0) { [void]$blockedReasons.Add('Final ocvalidate report is not valid with exit code 0.') }
    $versionConfigPath = Join-Path $script:RepoRoot 'config\versions\sequoia.json'
    if (-not (Test-Path -LiteralPath $versionConfigPath -PathType Leaf)) { [void]$blockedReasons.Add('Pinned macOS/OpenCore version configuration is missing.') }
    else {
        $versionConfig = Get-Content -LiteralPath $versionConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $expectedVersion = [string](Get-PropertyValue (Get-PropertyValue $versionConfig 'opencore') 'version')
        if (-not [string]::IsNullOrWhiteSpace($expectedVersion) -and $validationVersion -ne $expectedVersion) { [void]$blockedReasons.Add("Validation used OpenCore '$validationVersion' but the pinned configuration requires '$expectedVersion'.") }
    }
    Write-DevintoshStepLog $step "Final OpenCore validation state: $validationStatus; version: $validationVersion." $(if($blockedReasons.Count -eq 0){'PASS'}else{'WARN'})

    $step++; Write-DevintoshProgress $step $totalSteps 'Computing conservative readiness decision'
    $status = 'Ready'
    $decisionReasons = [System.Collections.Generic.List[string]]::new()
    if ($blockedReasons.Count -gt 0) {
        $status='Blocked'
        foreach($reason in @($blockedReasons)){[void]$decisionReasons.Add($reason)}
    } elseif ($needsProfile.Count -gt 0) {
        $status='NeedsProfile'
        foreach($state in @($needsProfile)){[void]$decisionReasons.Add("$($state.key) remains unresolved or requires a matching capability profile.")}
    } elseif ($needsValidation.Count -gt 0) {
        $status='NeedsValidation'
        foreach($state in @($needsValidation)){[void]$decisionReasons.Add("$($state.key) remains validation-required.")}
    } else {
        [void]$decisionReasons.Add('All required capability stages are resolved and the final generated config.plist passed the pinned ocvalidate.')
    }
    Write-DevintoshStepLog $step "Readiness decision: $status." $(if($status -eq 'Ready'){'PASS'}else{'WARN'})

    $step++; Write-DevintoshProgress $step $totalSteps 'Writing transactional readiness report'
    $report=[ordered]@{
        schemaVersion=1
        generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        status=$status
        applied=$false
        policy='conservative-preboot-readiness-gate'
        sourceReports=@($loaded | ForEach-Object { [pscustomobject]@{ key=$_.key; path=$_.path; required=$_.required; exists=$_.exists; valid=$_.valid; status=(Get-ReportStatus $_) } })
        capabilityStates=@($states)
        validation=[pscustomobject]@{ status=$validationStatus; validatorExitCode=$validatorExit; openCoreVersion=$validationVersion; target='build/efi/EFI/OC/config.plist' }
        reasons=@($decisionReasons)
        blockingIssues=@($blockedReasons)
        generatedArtifacts=@('build/opencore/readiness-report.json')
        intentionallyNotGenerated=@(
            'SMBIOS unique identifiers',
            'GPU spoofing or DeviceProperties',
            'ACPI patches or SSDTs',
            'USB port maps',
            'Audio layout IDs or routing',
            'Network interface configuration',
            'Any hardware-specific mutation'
        )
    }
    Write-ReportTransactional ([pscustomobject]$report)
    Write-DevintoshStepLog $step 'Readiness report written transactionally.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Finalizing readiness gate'
    Write-DevintoshLog 'INFO' "Readiness gate completed with state: $status. No configuration mutation was performed."
    Complete-DevintoshTransaction
    Complete-DevintoshProgress 'Readiness evaluation complete'
    $EXIT_CODE=$script:EXIT_SUCCESS
}
catch {
    Write-DevintoshLog 'ERROR' "Readiness gate failed: $($_.Exception.Message)"
    try {
        $ok=Invoke-DevintoshRollback
        if(-not $ok){$EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE}
    } catch { $EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE }
    if($EXIT_CODE -eq $script:EXIT_SUCCESS){$EXIT_CODE=$script:EXIT_GENERAL_FAILURE}
}
exit $EXIT_CODE
