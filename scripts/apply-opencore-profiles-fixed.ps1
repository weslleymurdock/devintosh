#requires -Version 5.1
[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\console.ps1"
. "$PSScriptRoot\lib\logging.ps1"
. "$PSScriptRoot\lib\progress.ps1"
. "$PSScriptRoot\lib\rollback.ps1"
. "$PSScriptRoot\lib\opencore-profile-engine.ps1"

$EXIT_CODE = $script:EXIT_SUCCESS
$step = 0
$totalSteps = 7
$outputRoot = Join-Path $script:BuildRoot 'opencore'
$resolutionPath = Join-Path $outputRoot 'hardware-resolution.json'
$configPath = Join-Path $script:BuildRoot 'efi\EFI\OC\config.plist'
$reportPath = Join-Path $outputRoot 'profile-application-report.json'

function Read-JsonFileLocal {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Required JSON file not found: $Path" }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-AllProfilesLocal {
    $root = Join-Path $script:RepoRoot 'config\hardware'
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    $profiles = [System.Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue)) {
        try {
            $profile = Read-JsonFileLocal $file.FullName
            if ($null -ne $profile.id) { [void]$profiles.Add($profile) }
        } catch { Write-DevintoshLog 'WARN' "Ignoring invalid profile $($file.FullName): $($_.Exception.Message)" }
    }
    return @($profiles.ToArray())
}

try {
    $step++
    Write-DevintoshProgress $step $totalSteps 'Checking resolved hardware profile and candidate configuration'
    if (-not (Test-IsAdministrator)) { $EXIT_CODE=$script:EXIT_INSUFFICIENT_PRIVILEGES; throw 'Administrator privileges are required.' }
    if (-not (Test-Path -LiteralPath $resolutionPath)) { $EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND; throw "Run configure-opencore.ps1 first: $resolutionPath" }
    if (-not (Test-Path -LiteralPath $configPath)) { $EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND; throw "OpenCore candidate not found: $configPath" }
    Write-DevintoshStepLog $step 'Hardware resolution and OpenCore candidate are available.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Loading matched declarative hardware profiles'
    $resolution = Read-JsonFileLocal $resolutionPath
    $matchedIds = @(Get-ProfileArray (Get-ProfileProperty $resolution 'matchedProfiles'))
    $allProfiles = @(Get-AllProfilesLocal)
    $matchedProfiles = [System.Collections.Generic.List[object]]::new()
    foreach ($profile in $allProfiles) {
        $id = [string](Get-ProfileProperty $profile 'id')
        if ($matchedIds -contains $id) { [void]$matchedProfiles.Add($profile) }
    }
    Write-DevintoshLog 'INFO' "Matched profile IDs: $($matchedIds -join ', ')."
    Write-DevintoshStepLog $step "Loaded $($matchedProfiles.Count) matched profile(s) for fragment application." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Checking profile policies and fragment conflicts'
    $operations = @(Get-ProfilePlistOperations $matchedProfiles)
    $conflicts = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($operation in $operations) {
        $pathKey = $operation.Path -join '/'
        if ($seen.ContainsKey($pathKey) -and $seen[$pathKey].Fingerprint -ne $operation.Fingerprint) {
            [void]$conflicts.Add([pscustomobject]@{ path=$pathKey; firstProfile=$seen[$pathKey].ProfileId; secondProfile=$operation.ProfileId })
        } elseif (-not $seen.ContainsKey($pathKey)) {
            $seen[$pathKey] = $operation
        }
    }
    if ($conflicts.Count -gt 0) {
        $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE
        throw "Conflicting OpenCore profile fragments detected at $($conflicts[0].path)."
    }
    Write-DevintoshStepLog $step "Fragment policy check passed. Declarative operations available: $($operations.Count)." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Loading generated OpenCore candidate'
    $xml = New-Object System.Xml.XmlDocument
    $xml.PreserveWhitespace = $true
    $xml.Load($configPath)
    $root = [System.Xml.XmlElement]$xml.DocumentElement.SelectSingleNode('/plist/dict')
    if ($null -eq $root) { $EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE; throw 'Generated config.plist has an invalid plist root.' }
    Write-DevintoshStepLog $step 'Generated OpenCore candidate loaded.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Applying safe profile fragments'
    $application = Apply-OpenCoreProfileFragments -Root $root -Profiles $matchedProfiles
    if ($application.status -eq 'Conflict') { $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw 'OpenCore profile fragment conflict detected during application.' }
    if ((@($application.applied)).Count -gt 0) {
        Write-DevintoshLog 'INFO' "Applied profile fragment paths: $((@($application.applied) | ForEach-Object { $_.profile + ':' + $_.path }) -join ', ')."
    }
    Write-DevintoshStepLog $step "Applied $(@($application.applied).Count) profile fragment operation(s); skipped validation-required profiles: $(@($application.skippedValidation).Count)." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Writing profile-applied OpenCore candidate'
    if (-not (Test-Path -LiteralPath $script:BackupRoot)) { New-Item -ItemType Directory -Path $script:BackupRoot -Force | Out-Null }
    $backupStamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff', [Globalization.CultureInfo]::InvariantCulture)
    $backupPath = Join-Path $script:BackupRoot ("config-{0}.plist" -f $backupStamp)
    Copy-Item -LiteralPath $configPath -Destination $backupPath -Force
    Add-DevintoshRollbackAction "Restore OpenCore candidate from $backupPath" { if (Test-Path -LiteralPath $backupPath) { Copy-Item -LiteralPath $backupPath -Destination $configPath -Force } }
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $settings.Indent = $true
    $writer = [System.Xml.XmlWriter]::Create($configPath, $settings)
    try { $xml.Save($writer) } finally { $writer.Dispose() }
    if (-not (Test-Path -LiteralPath $configPath)) { $EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE; throw 'Profile-applied config.plist was not created.' }
    Write-DevintoshStepLog $step "Profile-applied candidate written to $configPath." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Writing profile application report'
    $report = [ordered]@{
        schemaVersion = 1
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        sourceResolution = 'build/opencore/hardware-resolution.json'
        status = 'Applied'
        matchedProfiles = @($matchedIds)
        appliedOperations = @($application.applied)
        skippedValidationRequiredProfiles = @($application.skippedValidation)
        conflicts = @($application.conflicts)
        unresolvedCapabilities = @((Get-ProfileProperty $resolution 'unresolvedCapabilities'))
        needsValidation = @((Get-ProfileProperty $resolution 'needsValidation'))
        generatedArtifact = 'build/efi/EFI/OC/config.plist'
    }
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    Complete-DevintoshTransaction
    Write-DevintoshStepLog $step 'Profile application report written.' 'PASS'
    Complete-DevintoshProgress 'OpenCore profile fragments applied'
    exit $script:EXIT_SUCCESS
}
catch {
    Write-DevintoshStepLog $step "OpenCore profile application failed: $($_.Exception.Message)" 'FAIL'
    Write-DevintoshLog 'ERROR' $_.Exception.ToString()
    $rollbackOk = Invoke-DevintoshRollback
    if (-not $rollbackOk) { $EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE }
    if ($EXIT_CODE -eq $script:EXIT_SUCCESS) { $EXIT_CODE=$script:EXIT_GENERAL_FAILURE }
    exit $EXIT_CODE
}