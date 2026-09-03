#requires -Version 5.1
<#
.SYNOPSIS
    Resolves the kext set for the current OpenCore hardware profile.

.DESCRIPTION
    Builds a deterministic, data-driven kext plan from the generic core manifest and
    kext requirements declared by matched hardware profiles. It does not download,
    install, copy, or enable any kext. Release metadata, SHA-256, license information,
    dependencies, and payload names are validated before a plan is emitted.

    Unknown hardware remains supported: hardware profiles that do not exist simply
    contribute no hardware-specific kexts. A validation-required profile is reported as
    NeedsValidation rather than being treated as an error.

.PARAMETER Force
    Allows the existing resolution report to be replaced.

.EXIT CODES
    0 = Kext resolution completed.
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
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\console.ps1"
. "$PSScriptRoot\lib\logging.ps1"
. "$PSScriptRoot\lib\progress.ps1"

$EXIT_CODE = $script:EXIT_SUCCESS
$step = 0
$totalSteps = 7
$outputRoot = Join-Path $script:BuildRoot 'opencore'
$resolutionPath = Join-Path $outputRoot 'hardware-resolution.json'
$catalogPath = Join-Path $script:RepoRoot 'config\kexts\catalog.json'
$corePath = Join-Path $script:RepoRoot 'config\kexts\core.json'
$profilesRoot = Join-Path $script:RepoRoot 'config\hardware'
$reportPath = Join-Path $outputRoot 'kext-resolution.json'

function Read-JsonFileLocal {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Required JSON file not found: $Path" }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-PropertyValue {
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-ArrayValue {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return @() }
    return @($Value)
}

function Get-AllProfilesLocal {
    if (-not (Test-Path -LiteralPath $profilesRoot)) { return @() }
    $profiles = [System.Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $profilesRoot -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue)) {
        try {
            $profile = Read-JsonFileLocal $file.FullName
            $id = [string](Get-PropertyValue $profile 'id')
            if (-not [string]::IsNullOrWhiteSpace($id)) { [void]$profiles.Add($profile) }
        } catch {
            Write-DevintoshLog 'WARN' "Ignoring invalid hardware profile $($file.FullName): $($_.Exception.Message)"
        }
    }
    return @($profiles.ToArray())
}

function Get-CatalogMap {
    param([Parameter(Mandatory)]$Catalog)
    $map = @{}
    foreach ($artifact in @(Get-ArrayValue (Get-PropertyValue $Catalog 'artifacts'))) {
        $id = [string](Get-PropertyValue $artifact 'id')
        if ([string]::IsNullOrWhiteSpace($id)) { throw 'Kext catalog contains an artifact without an id.' }
        if ($map.ContainsKey($id)) { throw "Kext catalog contains duplicate artifact id '$id'." }
        $map[$id] = $artifact
    }
    return $map
}

function Add-KextRequirement {
    param(
        [Parameter(Mandatory)][hashtable]$Requested,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][bool]$RequiresValidation
    )
    if ([string]::IsNullOrWhiteSpace($Id)) { throw "Empty kext requirement declared by $Source." }
    if (-not $Requested.ContainsKey($Id)) {
        $Requested[$Id] = [pscustomobject]@{
            id = $Id
            sources = [System.Collections.Generic.List[string]]::new()
            requiresValidation = $RequiresValidation
        }
    } else {
        if ($RequiresValidation) { $Requested[$Id].requiresValidation = $true }
    }
    if (-not ($Requested[$Id].sources -contains $Source)) { [void]$Requested[$Id].sources.Add($Source) }
}

function Resolve-DependencyOrder {
    param(
        [Parameter(Mandatory)][hashtable]$CatalogMap,
        [Parameter(Mandatory)][hashtable]$Requested
    )

    $ordered = [System.Collections.Generic.List[string]]::new()
    $visiting = @{}
    $visited = @{}

    function Visit([string]$Id) {
        if ($visited.ContainsKey($Id)) { return }
        if ($visiting.ContainsKey($Id)) { throw "Kext dependency cycle detected at '$Id'." }
        if (-not $CatalogMap.ContainsKey($Id)) { throw "Required kext '$Id' is missing from the catalog." }

        $visiting[$Id] = $true
        $artifact = $CatalogMap[$Id]
        foreach ($dependency in @(Get-ArrayValue (Get-PropertyValue $artifact 'dependencies'))) {
            $dependencyId = [string]$dependency
            if ([string]::IsNullOrWhiteSpace($dependencyId)) { throw "Kext '$Id' declares an empty dependency." }
            Visit $dependencyId
        }
        $visiting.Remove($Id)
        $visited[$Id] = $true
        [void]$ordered.Add($Id)
    }

    foreach ($id in @($Requested.Keys | Sort-Object)) { Visit ([string]$id) }
    return @($ordered.ToArray())
}

try {
    $step++
    Write-DevintoshProgress $step $totalSteps 'Checking hardware resolution and kext manifests'
    if (-not (Test-Path -LiteralPath $resolutionPath)) { $EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND; throw "Run configure-opencore.ps1 first: $resolutionPath" }
    if (-not (Test-Path -LiteralPath $catalogPath)) { $EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND; throw "Kext catalog not found: $catalogPath" }
    if (-not (Test-Path -LiteralPath $corePath)) { $EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND; throw "Core kext manifest not found: $corePath" }
    if ((Test-Path -LiteralPath $reportPath) -and -not $Force) { $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw "Kext resolution report already exists. Re-run with -Force to replace it: $reportPath" }
    Write-DevintoshStepLog $step 'Hardware resolution and kext manifests are available.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Loading generic kext catalog and core requirements'
    $resolution = Read-JsonFileLocal $resolutionPath
    $catalog = Read-JsonFileLocal $catalogPath
    $core = Read-JsonFileLocal $corePath
    $catalogMap = Get-CatalogMap $catalog
    $requested = @{}
    foreach ($id in @(Get-ArrayValue (Get-PropertyValue $core 'requiredKexts'))) {
        Add-KextRequirement -Requested $requested -Id ([string]$id) -Source 'core' -RequiresValidation $false
    }
    Write-DevintoshStepLog $step "Loaded $($catalogMap.Count) catalog artifact(s) and $($requested.Count) core requirement(s)." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Collecting kext requirements from matched hardware profiles'
    $matchedIds = @(Get-ArrayValue (Get-PropertyValue $resolution 'matchedProfiles'))
    $profiles = @(Get-AllProfilesLocal)
    $matchedProfiles = [System.Collections.Generic.List[object]]::new()
    foreach ($profile in $profiles) {
        $id = [string](Get-PropertyValue $profile 'id')
        if ($matchedIds -contains $id) { [void]$matchedProfiles.Add($profile) }
    }
    foreach ($profile in $matchedProfiles) {
        $profileId = [string](Get-PropertyValue $profile 'id')
        $openCore = Get-PropertyValue $profile 'opencore'
        $policy = [string](Get-PropertyValue $openCore 'policy')
        $requiresValidation = $policy -eq 'validation-required'
        foreach ($id in @(Get-ArrayValue (Get-PropertyValue $profile 'kexts'))) {
            Add-KextRequirement -Requested $requested -Id ([string]$id) -Source $profileId -RequiresValidation $requiresValidation
        }
    }
    Write-DevintoshStepLog $step "Collected $($requested.Count) unique kext requirement(s) from $($matchedProfiles.Count) matched profile(s)." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Validating kext metadata, licenses, payloads, and dependencies'
    foreach ($id in @($requested.Keys)) {
        $artifact = $catalogMap[$id]
        $version = [string](Get-PropertyValue $artifact 'version')
        $url = [string](Get-PropertyValue $artifact 'downloadUrl')
        $sha = [string](Get-PropertyValue $artifact 'sha256')
        $license = [string](Get-PropertyValue $artifact 'license')
        $redistributable = Get-PropertyValue $artifact 'redistributable'
        $payloads = @(Get-ArrayValue (Get-PropertyValue $artifact 'payloads'))
        if ([string]::IsNullOrWhiteSpace($version) -or [string]::IsNullOrWhiteSpace($url) -or [string]::IsNullOrWhiteSpace($sha) -or [string]::IsNullOrWhiteSpace($license)) {
            $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE
            throw "Kext catalog entry '$id' has incomplete release metadata."
        }
        if ($sha -notmatch '^[0-9a-fA-F]{64}$') { $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw "Kext '$id' has an invalid SHA-256 value." }
        if ($redistributable -ne $true) { $EXIT_CODE=$script:EXIT_UNSUPPORTED_CONFIGURATION; throw "Kext '$id' is not explicitly marked redistributable." }
        if ($payloads.Count -eq 0) { $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw "Kext '$id' declares no payloads." }
        foreach ($dependency in @(Get-ArrayValue (Get-PropertyValue $artifact 'dependencies'))) {
            $dependencyId = [string]$dependency
            if (-not $catalogMap.ContainsKey($dependencyId)) { $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw "Kext '$id' depends on uncatalogued kext '$dependencyId'." }
        }
    }
    Write-DevintoshStepLog $step 'All requested kext metadata passed manifest validation.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Resolving deterministic kext dependency order'
    $orderedIds = @(Resolve-DependencyOrder -CatalogMap $catalogMap -Requested $requested)
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $orderedIds) {
        $artifact = $catalogMap[$id]
        [void]$entries.Add([ordered]@{
            id = $id
            name = [string](Get-PropertyValue $artifact 'name')
            version = [string](Get-PropertyValue $artifact 'version')
            kind = [string](Get-PropertyValue $artifact 'kind')
            repository = [string](Get-PropertyValue $artifact 'repository')
            releaseTag = [string](Get-PropertyValue $artifact 'releaseTag')
            assetName = [string](Get-PropertyValue $artifact 'assetName')
            downloadUrl = [string](Get-PropertyValue $artifact 'downloadUrl')
            sha256 = ([string](Get-PropertyValue $artifact 'sha256')).ToLowerInvariant()
            license = [string](Get-PropertyValue $artifact 'license')
            redistributable = [bool](Get-PropertyValue $artifact 'redistributable')
            requiresLicenseNotice = [bool](Get-PropertyValue $artifact 'requiresLicenseNotice')
            payloads = @(Get-ArrayValue (Get-PropertyValue $artifact 'payloads'))
            dependencies = @(Get-ArrayValue (Get-PropertyValue $artifact 'dependencies'))
            sources = @($requested[$id].sources)
            requiresValidation = [bool]$requested[$id].requiresValidation
        })
    }
    Write-DevintoshStepLog $step "Resolved $($entries.Count) kext artifact(s) in dependency-safe order." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Writing hardware-agnostic kext resolution report'
    $requiresValidationIds = @($entries | Where-Object { $_.requiresValidation } | ForEach-Object { $_.id })
    $status = if ($requiresValidationIds.Count -gt 0) { 'NeedsValidation' } else { 'Resolved' }
    $report = [ordered]@{
        schemaVersion = 1
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        sourceResolution = 'build/opencore/hardware-resolution.json'
        status = $status
        matchedProfiles = @($matchedIds)
        requestedKextCount = $entries.Count
        validationRequiredKexts = $requiresValidationIds
        kexts = @($entries)
        binaryAssetsGenerated = $false
        intentionallyNotDownloaded = $true
        notes = @(
            'This stage resolves metadata only; it does not download or install binaries.',
            'Unknown hardware may produce only the generic core set and is not mapped to unrelated profiles.',
            'Validation-required profiles remain visible in the plan and are not silently promoted to validated hardware.'
        )
    }
    $report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    Write-DevintoshStepLog $step "Kext resolution report written with status $status." 'PASS'
    Complete-DevintoshProgress 'Kext resolution complete'
    exit $script:EXIT_SUCCESS
}
catch {
    Write-DevintoshStepLog $step "Kext resolution failed: $($_.Exception.Message)" 'FAIL'
    Write-DevintoshLog 'ERROR' $_.Exception.ToString()
    exit $EXIT_CODE
}
