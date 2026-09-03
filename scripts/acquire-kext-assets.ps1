#requires -Version 5.1
<##
.SYNOPSIS
    Downloads, verifies, extracts, and stages resolved OpenCore kext assets.
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
$resolutionPath = Join-Path $outputRoot 'kext-resolution.json'
$catalogPath = Join-Path $script:RepoRoot 'config\kexts\catalog.json'
$stageRoot = Join-Path $script:BuildRoot 'efi\EFI\OC\Kexts'
$downloadRoot = Join-Path $script:BuildRoot 'downloads\kexts'
$tempRoot = Join-Path $script:BuildRoot 'temp\kexts'
$assetReportPath = Join-Path $outputRoot 'kext-assets.json'
$licenseRoot = Join-Path $outputRoot 'licenses'

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

function Get-SafeFileName {
    param([Parameter(Mandatory)][string]$Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $result = $Name
    foreach ($char in $invalid) { $result = $result.Replace([string]$char, '_') }
    if ([string]::IsNullOrWhiteSpace($result)) { throw 'Artifact name resolves to an empty filename.' }
    return $result
}

function Remove-PathIfExists {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
}

function Get-DirectorySha256 {
    param([Parameter(Mandatory)][string]$Path)
    $files = @(Get-ChildItem -LiteralPath $Path -File -Recurse | Sort-Object FullName)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($Path.Length).TrimStart('\\','/')
            $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            [void]$lines.Add(('{0}  {1}' -f $hash, $relative))
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
        $digest = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($digest) -replace '-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Resolve-PayloadMatch {
    param(
        [Parameter(Mandatory)][string]$ExtractRoot,
        [Parameter(Mandatory)][string]$Payload,
        [AllowNull()][object]$Selection
    )

    $matches = @(Get-ChildItem -LiteralPath $ExtractRoot -Directory -Filter $Payload -Recurse -ErrorAction SilentlyContinue)
    if ($matches.Count -eq 1) {
        return $matches[0]
    }
    if ($matches.Count -eq 0) {
        throw "Declared payload '$Payload' was not found in the extracted archive."
    }

    $selectorRegex = [string](Get-PropertyValue $Selection 'preferredPathRegex')
    if ([string]::IsNullOrWhiteSpace($selectorRegex)) {
        $paths = @($matches | ForEach-Object { $_.FullName.Substring($ExtractRoot.Length).TrimStart('\\','/') })
        throw "Payload '$Payload' is ambiguous: found $($matches.Count) candidates and no payload selector was declared. Candidates: $($paths -join '; ')"
    }

    try {
        $selected = @($matches | Where-Object {
            $relative = $_.FullName.Substring($ExtractRoot.Length).TrimStart('\\','/')
            $relative -match $selectorRegex
        })
    } catch {
        throw "Invalid payload selector regex for '$Payload': $selectorRegex. $($_.Exception.Message)"
    }

    if ($selected.Count -eq 1) { return $selected[0] }

    $candidatePaths = @($matches | ForEach-Object { $_.FullName.Substring($ExtractRoot.Length).TrimStart('\\','/') })
    $selectedPaths = @($selected | ForEach-Object { $_.FullName.Substring($ExtractRoot.Length).TrimStart('\\','/') })
    if ($selected.Count -eq 0) {
        throw "Payload '$Payload' selector '$selectorRegex' matched none of the $($matches.Count) candidates. Candidates: $($candidatePaths -join '; ')"
    }
    throw "Payload '$Payload' selector '$selectorRegex' is still ambiguous: matched $($selected.Count) candidates. Selected: $($selectedPaths -join '; ')"
}

try {
    if (-not (Test-IsAdministrator)) { $EXIT_CODE=$script:EXIT_INSUFFICIENT_PRIVILEGES; throw 'Administrator privileges are required for kext asset staging.' }

    $step++
    Write-DevintoshProgress $step $totalSteps 'Checking kext resolution and acquisition directories'
    if (-not (Test-Path -LiteralPath $resolutionPath)) { $EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND; throw "Run resolve-kexts.ps1 first: $resolutionPath" }
    if (-not (Test-Path -LiteralPath $catalogPath)) { $EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND; throw "Kext catalog not found: $catalogPath" }
    foreach ($dir in @($downloadRoot,$tempRoot,$stageRoot,$licenseRoot)) { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null } }
    Write-DevintoshStepLog $step 'Kext resolution and acquisition directories are available.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Loading resolved kext metadata'
    $resolution = Read-JsonFileLocal $resolutionPath
    $catalog = Read-JsonFileLocal $catalogPath
    $entries = @(Get-ArrayValue (Get-PropertyValue $resolution 'kexts'))
    if ($entries.Count -eq 0) { Write-DevintoshStepLog $step 'No kext artifacts are required by the current hardware resolution.' 'WARN' } else { Write-DevintoshStepLog $step "Loaded $($entries.Count) resolved kext artifact(s)." 'PASS' }

    $step++
    Write-DevintoshProgress $step $totalSteps 'Validating declared acquisition metadata'
    $catalogMap = @{}
    foreach ($artifact in @(Get-ArrayValue (Get-PropertyValue $catalog 'artifacts'))) {
        $id = [string](Get-PropertyValue $artifact 'id')
        if (-not [string]::IsNullOrWhiteSpace($id)) { $catalogMap[$id] = $artifact }
    }
    foreach ($entry in $entries) {
        $id = [string](Get-PropertyValue $entry 'id')
        if (-not $catalogMap.ContainsKey($id)) { $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw "Resolved kext '$id' is missing from catalog." }
        $artifact = $catalogMap[$id]
        $url = [string](Get-PropertyValue $artifact 'downloadUrl')
        $sha = [string](Get-PropertyValue $artifact 'sha256')
        $assetName = [string](Get-PropertyValue $artifact 'assetName')
        $payloads = @(Get-ArrayValue (Get-PropertyValue $artifact 'payloads'))
        if ($url -notmatch '^https://') { $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw "Kext '$id' has a non-HTTPS download URL." }
        if ($sha -notmatch '^[0-9a-fA-F]{64}$') { $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw "Kext '$id' has an invalid SHA-256 value." }
        if ([string]::IsNullOrWhiteSpace($assetName) -or $payloads.Count -eq 0) { $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw "Kext '$id' has incomplete acquisition metadata." }
        $selectionMap = Get-PropertyValue $artifact 'payloadSelection'
        foreach ($payload in $payloads) {
            $selection = Get-PropertyValue $selectionMap ([string]$payload)
            $selectorRegex = [string](Get-PropertyValue $selection 'preferredPathRegex')
            if (-not [string]::IsNullOrWhiteSpace($selectorRegex)) {
                try { [void][regex]::new($selectorRegex) } catch { $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw "Kext '$id' has an invalid payload selector for '$payload': $selectorRegex" }
            }
        }
    }
    Write-DevintoshStepLog $step 'All acquisition metadata passed validation.' 'PASS'

    Start-DevintoshTransaction
    $originalStage = Join-Path $tempRoot 'original-stage'
    Remove-PathIfExists $originalStage
    if (Test-Path -LiteralPath $stageRoot) {
        Copy-Item -LiteralPath $stageRoot -Destination $originalStage -Recurse -Force
        Add-DevintoshRollbackAction -Name 'Restore previous staged kext payloads' -Action { Remove-PathIfExists $stageRoot; if (Test-Path -LiteralPath $originalStage) { Copy-Item -LiteralPath $originalStage -Destination $stageRoot -Recurse -Force } }
    } else {
        Add-DevintoshRollbackAction -Name 'Remove newly created kext staging directory' -Action { Remove-PathIfExists $stageRoot }
    }

    $step++
    Write-DevintoshProgress $step $totalSteps 'Downloading and verifying kext release archives'
    $downloaded = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $entries) {
        $id = [string](Get-PropertyValue $entry 'id')
        $artifact = $catalogMap[$id]
        $assetName = Get-SafeFileName ([string](Get-PropertyValue $artifact 'assetName'))
        $downloadPath = Join-Path $downloadRoot $assetName
        $expectedSha = ([string](Get-PropertyValue $artifact 'sha256')).ToLowerInvariant()
        $url = [string](Get-PropertyValue $artifact 'downloadUrl')
        if (Test-Path -LiteralPath $downloadPath) {
            $actualSha = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actualSha -ne $expectedSha) { Remove-Item -LiteralPath $downloadPath -Force }
        }
        if (-not (Test-Path -LiteralPath $downloadPath)) {
            try { Invoke-WebRequest -Uri $url -OutFile $downloadPath -UseBasicParsing } catch { $EXIT_CODE=$script:EXIT_DEPENDENCY_FAILURE; throw "Failed to download '$id': $($_.Exception.Message)" }
        }
        $actualSha = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualSha -ne $expectedSha) { $EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE; throw "SHA-256 verification failed for '$id'. Expected $expectedSha, got $actualSha." }
        [void]$downloaded.Add([pscustomobject]@{ id=$id; path=$downloadPath; sha256=$actualSha })
    }
    Write-DevintoshStepLog $step "Downloaded and SHA-256 verified $($downloaded.Count) archive(s)." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Extracting and validating declared kext payloads'
    $stagedEntries = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $downloaded) {
        $id = [string]$item.id
        $artifact = $catalogMap[$id]
        $payloads = @(Get-ArrayValue (Get-PropertyValue $artifact 'payloads'))
        $selectionMap = Get-PropertyValue $artifact 'payloadSelection'
        $extractRoot = Join-Path $tempRoot $id
        Remove-PathIfExists $extractRoot
        New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
        try { Expand-Archive -LiteralPath $item.path -DestinationPath $extractRoot -Force } catch { $EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE; throw "Failed to extract '$id': $($_.Exception.Message)" }
        foreach ($payload in $payloads) {
            $selection = Get-PropertyValue $selectionMap ([string]$payload)
            $match = Resolve-PayloadMatch -ExtractRoot $extractRoot -Payload ([string]$payload) -Selection $selection
            $source = $match.FullName
            $relativeSource = $source.Substring($extractRoot.Length).TrimStart('\\','/')
            $destination = Join-Path $stageRoot ([System.IO.Path]::GetFileName($source))
            if (Test-Path -LiteralPath $destination) {
                if (-not $Force) { $EXIT_CODE=$script:EXIT_UNSUPPORTED_CONFIGURATION; throw "Kext payload '$payload' already exists. Re-run with -Force to replace it." }
                Remove-Item -LiteralPath $destination -Recurse -Force
            }
            Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
            $payloadSha = Get-DirectorySha256 $destination
            [void]$stagedEntries.Add([ordered]@{ id=$id; version=[string](Get-PropertyValue $artifact 'version'); payload=$payload; sourcePath=$relativeSource; payloadSha256=$payloadSha; path=('build/efi/EFI/OC/Kexts/{0}' -f [System.IO.Path]::GetFileName($source)) })
        }
    }
    Write-DevintoshStepLog $step "Validated and staged $($stagedEntries.Count) kext payload(s)." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Writing license notices and asset manifest'
    $licenseEntries = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $entries) {
        $id = [string](Get-PropertyValue $entry 'id')
        $artifact = $catalogMap[$id]
        if ((Get-PropertyValue $artifact 'requiresLicenseNotice') -eq $true) {
            $license = [string](Get-PropertyValue $artifact 'license')
            $noticePath = Join-Path $licenseRoot (Get-SafeFileName ("{0}-{1}-LICENSE.txt" -f $id, (Get-PropertyValue $artifact 'version')))
            $notice = "Devintosh asset license notice`r`n`r`nArtifact: $id`r`nVersion: $([string](Get-PropertyValue $artifact 'version'))`r`nRepository: $([string](Get-PropertyValue $artifact 'repository'))`r`nLicense: $license`r`n`r`nThis file records the license metadata declared by the Devintosh asset catalog. Consult the upstream repository for the complete license text."
            Set-Content -LiteralPath $noticePath -Value $notice -Encoding UTF8
            [void]$licenseEntries.Add([ordered]@{ id=$id; license=$license; noticePath=('build/opencore/licenses/{0}' -f [System.IO.Path]::GetFileName($noticePath)) })
        }
    }
    $report = [ordered]@{
        schemaVersion=2
        generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        sourceResolution='build/opencore/kext-resolution.json'
        sourceCatalog='config/kexts/catalog.json'
        status=[string](Get-PropertyValue $resolution 'status')
        downloadRoot='build/downloads/kexts'
        stageRoot='build/efi/EFI/OC/Kexts'
        forceMode=[bool]$Force
        assets=@($downloaded | ForEach-Object { $artifact=$catalogMap[$_.id]; [ordered]@{ id=$_.id; name=[string](Get-PropertyValue $artifact 'name'); version=[string](Get-PropertyValue $artifact 'version'); repository=[string](Get-PropertyValue $artifact 'repository'); releaseTag=[string](Get-PropertyValue $artifact 'releaseTag'); assetName=[string](Get-PropertyValue $artifact 'assetName'); downloadUrl=[string](Get-PropertyValue $artifact 'downloadUrl'); archiveSha256=$_.sha256; license=[string](Get-PropertyValue $artifact 'license'); redistributable=[bool](Get-PropertyValue $artifact 'redistributable'); dependencies=@(Get-ArrayValue (Get-PropertyValue $artifact 'dependencies')) } })
        payloads=@($stagedEntries)
        licenseNotices=@($licenseEntries)
        configKernelAddUpdated=$false
        notes=@('Archives are verified before extraction.','Only catalog-declared payloads are staged.','Payload ambiguity is resolved only by catalog-declared selectors.','Kernel -> Add is intentionally not modified in this stage.')
    }
    $report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $assetReportPath -Encoding UTF8
    Write-DevintoshStepLog $step 'Kext asset manifest and license notices written.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Finalizing kext asset transaction'
    Complete-DevintoshTransaction
    Write-DevintoshStepLog $step 'Kext asset transaction committed successfully.' 'PASS'
    Complete-DevintoshProgress 'Kext asset acquisition complete'
    exit $script:EXIT_SUCCESS
}
catch {
    Write-DevintoshStepLog ([Math]::Min($step, $totalSteps)) ("Kext asset acquisition failed: {0}" -f $_.Exception.Message) 'FAIL'
    try { Invoke-DevintoshRollback } catch { $EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE }
    exit $EXIT_CODE
}
