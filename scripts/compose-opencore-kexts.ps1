#requires -Version 5.1
<#
.SYNOPSIS
    Composes OpenCore Kernel/Add entries from verified staged kext assets.

.DESCRIPTION
    Hardware-agnostic configuration stage. Reads only the generated kext asset manifest
    and the staged kext bundles. It never identifies hardware and never invents kext
    executable paths: bundle metadata is inspected from Contents/Info.plist and the
    executable is verified before an entry is emitted.

    Kexts marked requiresValidation remain in the generated plan but are disabled in
    Kernel/Add. This prevents a known-but-unvalidated hardware profile from becoming
    an active configuration while preserving the resolved artifact for later validation.

    The existing Kernel/Add array is replaced atomically with the deterministic order
    from kext-resolution. Duplicate BundlePath values are rejected. Missing or malformed
    bundles are treated as asset-integrity failures.

.PARAMETER Force
    Required to replace the generated config.plist.

.EXIT CODES
    0 = Composition completed.
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
$totalSteps = 8
$outputRoot = Join-Path $script:BuildRoot 'opencore'
$assetsPath = Join-Path $outputRoot 'kext-assets.json'
$configPath = Join-Path $script:BuildRoot 'efi\EFI\OC\config.plist'
$stageRoot = Join-Path $script:BuildRoot 'efi\EFI\OC\Kexts'
$reportPath = Join-Path $outputRoot 'kext-composition-report.json'

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

function New-PlistElement {
    param(
        [Parameter(Mandatory)][System.Xml.XmlDocument]$Document,
        [Parameter(Mandatory)][string]$Type,
        [AllowEmptyString()][string]$Value = ''
    )
    $node = $Document.CreateElement($Type)
    if ($Type -notin @('true','false')) { $node.InnerText = $Value }
    return $node
}

function Find-PlistKey {
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Dict,[Parameter(Mandatory)][string]$Name)
    $matches = @($Dict.ChildNodes | Where-Object {
        $_.NodeType -eq 'Element' -and $_.Name -eq 'key' -and $_.InnerText -eq $Name
    })
    if ($matches.Count -gt 1) { throw "Duplicate plist key '$Name'." }
    if ($matches.Count -eq 0) { return $null }
    return [System.Xml.XmlElement]$matches[0]
}

function Get-PlistDictionary {
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Root,[Parameter(Mandatory)][string[]]$Path)
    $current = $Root
    foreach ($name in $Path) {
        $key = Find-PlistKey $current $name
        if ($null -eq $key) {
            $key = $current.OwnerDocument.CreateElement('key')
            $key.InnerText = $name
            [void]$current.AppendChild($key)
            $dict = $current.OwnerDocument.CreateElement('dict')
            [void]$current.AppendChild($dict)
            $current = $dict
            continue
        }
        $value = $key.NextSibling
        while ($null -ne $value -and $value.NodeType -ne 'Element') { $value = $value.NextSibling }
        if ($null -eq $value -or $value.Name -ne 'dict') { throw "Plist path '$($Path -join '/')' is not a dictionary." }
        $current = [System.Xml.XmlElement]$value
    }
    return $current
}

function New-KernelAddEntry {
    param(
        [Parameter(Mandatory)][System.Xml.XmlDocument]$Document,
        [Parameter(Mandatory)][string]$BundlePath,
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string]$PlistPath,
        [Parameter(Mandatory)][bool]$Enabled
    )
    $dict = $Document.CreateElement('dict')
    foreach ($pair in @(
        @('BundlePath','string',$BundlePath),
        @('Enabled',$(if ($Enabled) { 'true' } else { 'false' }),'') ,
        @('ExecutablePath','string',$ExecutablePath),
        @('PlistPath','string',$PlistPath)
    )) {
        $key = $Document.CreateElement('key')
        $key.InnerText = [string]$pair[0]
        [void]$dict.AppendChild($key)
        [void]$dict.AppendChild((New-PlistElement -Document $Document -Type ([string]$pair[1]) -Value ([string]$pair[2])))
    }
    return $dict
}

function Resolve-KextBundleMetadata {
    param(
        [Parameter(Mandatory)][string]$StageRoot,
        [Parameter(Mandatory)]$Entry
    )
    $relativePath = [string](Get-PropertyValue $Entry 'path')
    if ([string]::IsNullOrWhiteSpace($relativePath)) { throw "Kext '$([string](Get-PropertyValue $Entry 'id'))' has no staged path." }
    if ($relativePath -notmatch '^(?i)build/efi/EFI/OC/Kexts/') { throw "Kext '$([string](Get-PropertyValue $Entry 'id'))' has an unsafe staged path '$relativePath'." }

    $bundleName = [string](Get-PropertyValue $Entry 'payload')
    if ([string]::IsNullOrWhiteSpace($bundleName) -or -not $bundleName.EndsWith('.kext',[StringComparison]::OrdinalIgnoreCase)) {
        throw "Kext '$([string](Get-PropertyValue $Entry 'id'))' declares an invalid payload '$bundleName'."
    }
    $bundlePath = Join-Path $StageRoot $bundleName
    if (-not (Test-Path -LiteralPath $bundlePath -PathType Container)) { throw "Staged kext bundle not found: $bundlePath" }

    $infoPath = Join-Path $bundlePath 'Contents\Info.plist'
    if (-not (Test-Path -LiteralPath $infoPath -PathType Leaf)) { throw "Kext '$bundleName' is missing Contents/Info.plist." }

    $info = New-Object System.Xml.XmlDocument
    $info.PreserveWhitespace = $true
    try { $info.Load($infoPath) } catch { throw "Kext '$bundleName' has an invalid Contents/Info.plist: $($_.Exception.Message)" }
    $infoRoot = [System.Xml.XmlElement]$info.DocumentElement.SelectSingleNode('/plist/dict')
    if ($null -eq $infoRoot) { throw "Kext '$bundleName' Info.plist has no valid plist dictionary." }
    $executableKey = Find-PlistKey $infoRoot 'CFBundleExecutable'
    if ($null -eq $executableKey) { throw "Kext '$bundleName' Info.plist does not declare CFBundleExecutable." }
    $executableNode = $executableKey.NextSibling
    while ($null -ne $executableNode -and $executableNode.NodeType -ne 'Element') { $executableNode = $executableNode.NextSibling }
    if ($null -eq $executableNode -or $executableNode.Name -ne 'string' -or [string]::IsNullOrWhiteSpace($executableNode.InnerText)) { throw "Kext '$bundleName' has an invalid CFBundleExecutable value." }
    $executableName = $executableNode.InnerText.Trim()
    if ($executableName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $executableName.Contains('/') -or $executableName.Contains('\')) { throw "Kext '$bundleName' declares an unsafe executable name '$executableName'." }

    $executableRelative = Join-Path 'Contents\MacOS' $executableName
    $executableFullPath = Join-Path $bundlePath $executableRelative
    if (-not (Test-Path -LiteralPath $executableFullPath -PathType Leaf)) { throw "Kext '$bundleName' executable declared by Info.plist was not found: $executableRelative" }

    $bundlePathForOpenCore = $bundleName
    $plistPathForOpenCore = 'Contents/Info.plist'
    $executablePathForOpenCore = ($executableRelative -replace '\\','/')
    return [pscustomobject]@{
        id = [string](Get-PropertyValue $Entry 'id')
        version = [string](Get-PropertyValue $Entry 'version')
        bundlePath = $bundlePathForOpenCore
        executablePath = $executablePathForOpenCore
        plistPath = $plistPathForOpenCore
        enabled = -not [bool](Get-PropertyValue $Entry 'requiresValidation')
        requiresValidation = [bool](Get-PropertyValue $Entry 'requiresValidation')
        dependencies = @(Get-ArrayValue (Get-PropertyValue $Entry 'dependencies'))
        stagedPath = $relativePath
    }
}

function Set-KernelAdd {
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Root,[Parameter(Mandatory)][object[]]$Entries)
    $kernel = Get-PlistDictionary $Root @('Kernel')
    $existingKey = Find-PlistKey $kernel 'Add'
    if ($null -eq $existingKey) {
        $addKey = $kernel.OwnerDocument.CreateElement('key')
        $addKey.InnerText = 'Add'
        [void]$kernel.AppendChild($addKey)
    } else { $addKey = $existingKey }
    $old = $addKey.NextSibling
    while ($null -ne $old -and $old.NodeType -ne 'Element') { $old = $old.NextSibling }
    if ($null -ne $old) { [void]$kernel.RemoveChild($old) }
    $array = $kernel.OwnerDocument.CreateElement('array')
    foreach ($entry in $Entries) {
        [void]$array.AppendChild((New-KernelAddEntry -Document $kernel.OwnerDocument -BundlePath $entry.bundlePath -ExecutablePath $entry.executablePath -PlistPath $entry.plistPath -Enabled $entry.enabled))
    }
    [void]$kernel.InsertAfter($array,$addKey)
}

try {
    $step++
    Write-DevintoshProgress $step $totalSteps 'Checking verified kext assets and OpenCore candidate'
    if (-not (Test-IsAdministrator)) { $EXIT_CODE=$script:EXIT_INSUFFICIENT_PRIVILEGES; throw 'Administrator privileges are required.' }
    if (-not (Test-Path -LiteralPath $assetsPath)) { $EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND; throw "Run acquire-kext-assets.ps1 first: $assetsPath" }
    if (-not (Test-Path -LiteralPath $configPath)) { $EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND; throw "OpenCore candidate not found: $configPath" }
    if (-not (Test-Path -LiteralPath $stageRoot -PathType Container)) { $EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND; throw "Staged kext directory not found: $stageRoot" }
    Write-DevintoshStepLog $step 'Verified kext asset manifest and OpenCore candidate are available.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Loading deterministic kext asset manifest'
    $assets = Read-JsonFileLocal $assetsPath
    $entries = @(Get-ArrayValue (Get-PropertyValue $assets 'stagedPayloads'))
    if ($entries.Count -eq 0) { $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw 'Kext asset manifest contains no staged payloads.' }
    Write-DevintoshStepLog $step "Loaded $($entries.Count) staged kext payload(s)." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Inspecting kext bundle metadata and executable paths'
    $metadata = [System.Collections.Generic.List[object]]::new()
    $bundleNames = @{}
    foreach ($entry in $entries) {
        $item = Resolve-KextBundleMetadata -StageRoot $stageRoot -Entry $entry
        $key = $item.bundlePath.ToLowerInvariant()
        if ($bundleNames.ContainsKey($key)) { $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw "Duplicate kext BundlePath '$($item.bundlePath)' detected." }
        $bundleNames[$key] = $true
        [void]$metadata.Add($item)
    }
    Write-DevintoshStepLog $step "Validated $($metadata.Count) kext bundle(s) from their own Info.plist metadata." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Validating dependency-safe order and activation policy'
    $ordered = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $entries) {
        $item = @($metadata | Where-Object { $_.id -eq [string](Get-PropertyValue $entry 'id') })
        if ($item.Count -ne 1) { $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw "Unable to correlate staged kext '$([string](Get-PropertyValue $entry 'id'))' with its metadata." }
        [void]$ordered.Add($item[0])
    }
    $seen = @{}
    foreach ($item in $ordered) {
        foreach ($dependency in @($item.dependencies)) {
            if (-not $seen.ContainsKey([string]$dependency)) {
                $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE
                throw "Kext '$($item.id)' appears before its declared dependency '$dependency'."
            }
        }
        $seen[$item.id] = $true
    }
    $disabled = @($ordered | Where-Object { $_.requiresValidation } | ForEach-Object { $_.id })
    if ($disabled.Count -gt 0) { Write-DevintoshLog 'WARN' "Validation-required kexts will be present but disabled: $($disabled -join ', ')." }
    Write-DevintoshStepLog $step 'Kext order and validation policy passed.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Loading OpenCore Kernel Add configuration'
    $xml = New-Object System.Xml.XmlDocument
    $xml.PreserveWhitespace = $true
    $xml.Load($configPath)
    $root = [System.Xml.XmlElement]$xml.DocumentElement.SelectSingleNode('/plist/dict')
    if ($null -eq $root) { $EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE; throw 'Generated config.plist has an invalid plist root.' }
    Write-DevintoshStepLog $step 'OpenCore configuration loaded.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Composing deterministic Kernel Add entries'
    Set-KernelAdd -Root $root -Entries @($ordered)
    if (-not $Force) { $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw 'Use -Force to replace the generated OpenCore candidate.' }
    if (-not (Test-Path -LiteralPath $script:BackupRoot)) { New-Item -ItemType Directory -Path $script:BackupRoot -Force | Out-Null }
    $backupStamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff',[Globalization.CultureInfo]::InvariantCulture)
    $backupPath = Join-Path $script:BackupRoot ("config-kexts-{0}.plist" -f $backupStamp)
    Copy-Item -LiteralPath $configPath -Destination $backupPath -Force
    Add-DevintoshRollbackAction "Restore OpenCore candidate from $backupPath" { if (Test-Path -LiteralPath $backupPath) { Copy-Item -LiteralPath $backupPath -Destination $configPath -Force } }
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $settings.Indent = $true
    $writer = [System.Xml.XmlWriter]::Create($configPath,$settings)
    try { $xml.Save($writer) } finally { $writer.Dispose() }
    Write-DevintoshStepLog $step "Kernel/Add composed for $($ordered.Count) kext(s)." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Writing kext composition report'
    $report = [ordered]@{
        schemaVersion = 1
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        sourceAssets = 'build/opencore/kext-assets.json'
        status = if ($disabled.Count -gt 0) { 'NeedsValidation' } else { 'Applied' }
        entries = @($ordered | ForEach-Object { [ordered]@{ id=$_.id; version=$_.version; bundlePath=$_.bundlePath; executablePath=$_.executablePath; plistPath=$_.plistPath; enabled=$_.enabled; requiresValidation=$_.requiresValidation; dependencies=@($_.dependencies); stagedPath=$_.stagedPath } })
        disabledValidationRequiredKexts = @($disabled)
        generatedArtifact = 'build/efi/EFI/OC/config.plist'
    }
    $report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    Complete-DevintoshTransaction
    Write-DevintoshStepLog $step 'Kext composition report written.' 'PASS'
    Complete-DevintoshProgress 'OpenCore Kernel Add composition complete'
    exit $script:EXIT_SUCCESS
}
catch {
    Write-DevintoshStepLog $step "OpenCore kext composition failed: $($_.Exception.Message)" 'FAIL'
    Write-DevintoshLog 'ERROR' $_.Exception.ToString()
    $rollbackOk = Invoke-DevintoshRollback
    if (-not $rollbackOk) { $EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE }
    exit $EXIT_CODE
}
