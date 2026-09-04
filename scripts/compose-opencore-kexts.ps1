#requires -Version 5.1
<#
.SYNOPSIS
    Composes OpenCore Kernel/Add entries from verified staged kext assets.
.DESCRIPTION
    Hardware-agnostic configuration stage. Reads the generated kext asset manifest and
    staged kext bundles. It never identifies hardware and never invents executable paths.
    Kexts marked requiresValidation remain present but disabled.
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
    param([AllowNull()][object]$Object,[Parameter(Mandatory)][string]$Name)
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

function Get-RelativeStagePath {
    param([Parameter(Mandatory)][string]$FullPath,[Parameter(Mandatory)][string]$RootPath)
    $relative = $FullPath.Substring($RootPath.Length)
    return ($relative -replace '^[\\/]+','')
}

function Get-DirectorySha256 {
    param([Parameter(Mandatory)][string]$Path)
    $files = @(Get-ChildItem -LiteralPath $Path -File -Recurse | Sort-Object FullName)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($file in $files) {
            $relative = Get-RelativeStagePath -FullPath $file.FullName -RootPath $Path
            $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            [void]$lines.Add(('{0}  {1}' -f $hash,$relative))
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
        return (([BitConverter]::ToString($sha.ComputeHash($bytes))) -replace '-','').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function New-PlistElement {
    param([Parameter(Mandatory)][System.Xml.XmlDocument]$Document,[Parameter(Mandatory)][string]$Type,[AllowEmptyString()][string]$Value='')
    $node = $Document.CreateElement($Type)
    if ($Type -notin @('true','false')) { $node.InnerText = $Value }
    return $node
}

function Find-PlistKey {
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Dict,[Parameter(Mandatory)][string]$Name)
    $matches = @($Dict.ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.Name -eq 'key' -and $_.InnerText -eq $Name })
    if ($matches.Count -gt 1) { throw "Duplicate plist key '$Name'." }
    if ($matches.Count -eq 0) { return $null }
    return [System.Xml.XmlElement]$matches[0]
}

function New-KernelAddEntry {
    param([Parameter(Mandatory)][System.Xml.XmlDocument]$Document,[Parameter(Mandatory)]$Entry)
    $dict = $Document.CreateElement('dict')
    $values = @(
        @('Arch','string','x86_64'),
        @('BundlePath','string',[string]$Entry.bundlePath),
        @('Comment','string',('devintosh: {0} {1}' -f $Entry.id,$Entry.version)),
        @('Enabled',$(if($Entry.enabled){'true'}else{'false'}),''),
        @('ExecutablePath','string',[string]$Entry.executablePath),
        @('MaxKernel','string',''),
        @('MinKernel','string',''),
        @('PlistPath','string',[string]$Entry.plistPath)
    )
    foreach ($pair in $values) {
        $key = $Document.CreateElement('key')
        $key.InnerText = [string]$pair[0]
        [void]$dict.AppendChild($key)
        [void]$dict.AppendChild((New-PlistElement -Document $Document -Type ([string]$pair[1]) -Value ([string]$pair[2])))
    }
    return $dict
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

function Resolve-KextBundleMetadata {
    param([Parameter(Mandatory)][string]$StageRoot,[Parameter(Mandatory)]$Entry)
    $id = [string](Get-PropertyValue $Entry 'id')
    $relativePath = [string](Get-PropertyValue $Entry 'path')
    if ([string]::IsNullOrWhiteSpace($relativePath)) { throw "Kext '$id' has no staged path." }
    if ($relativePath -notmatch '^(?i)build/efi/EFI/OC/Kexts/') { throw "Kext '$id' has an unsafe staged path '$relativePath'." }
    $bundleName = [string](Get-PropertyValue $Entry 'payload')
    if ([string]::IsNullOrWhiteSpace($bundleName) -or -not $bundleName.EndsWith('.kext',[StringComparison]::OrdinalIgnoreCase)) { throw "Kext '$id' declares an invalid payload '$bundleName'." }
    $bundlePath = Join-Path $StageRoot $bundleName
    if (-not (Test-Path -LiteralPath $bundlePath -PathType Container)) { throw "Staged kext bundle not found: $bundlePath" }
    $manifestHash = [string](Get-PropertyValue $Entry 'payloadSha256')
    if ($manifestHash -notmatch '^[0-9a-fA-F]{64}$') { throw "Kext '$id' has an invalid payload SHA-256 in the asset manifest." }
    $actualHash = Get-DirectorySha256 $bundlePath
    if ($actualHash -ne $manifestHash.ToLowerInvariant()) { throw "Payload SHA-256 verification failed for '$id'. Expected $manifestHash, got $actualHash." }
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
    return [pscustomobject]@{
        id=$id; version=[string](Get-PropertyValue $Entry 'version'); bundlePath=$bundleName
        executablePath=($executableRelative -replace '\\','/'); plistPath='Contents/Info.plist'
        enabled=(-not [bool](Get-PropertyValue $Entry 'requiresValidation'))
        requiresValidation=[bool](Get-PropertyValue $Entry 'requiresValidation')
        dependencies=@(Get-ArrayValue (Get-PropertyValue $Entry 'dependencies'))
        stagedPath=$relativePath; payloadSha256=$actualHash
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
    foreach ($entry in $Entries) { [void]$array.AppendChild((New-KernelAddEntry -Document $kernel.OwnerDocument -Entry $entry)) }
    [void]$kernel.InsertAfter($array,$addKey)
}

try {
    $step++; Write-DevintoshProgress $step $totalSteps 'Checking verified kext assets and OpenCore candidate'
    if (-not (Test-IsAdministrator)) { $EXIT_CODE=$script:EXIT_INSUFFICIENT_PRIVILEGES; throw 'Administrator privileges are required.' }
    if (-not (Test-Path -LiteralPath $assetsPath)) { $EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND; throw "Run acquire-kext-assets.ps1 first: $assetsPath" }
    if (-not (Test-Path -LiteralPath $configPath)) { $EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND; throw "OpenCore candidate not found: $configPath" }
    if (-not (Test-Path -LiteralPath $stageRoot -PathType Container)) { $EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND; throw "Staged kext directory not found: $stageRoot" }
    Write-DevintoshStepLog $step 'Verified kext asset manifest and OpenCore candidate are available.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Loading deterministic kext asset manifest'
    $assets=Read-JsonFileLocal $assetsPath
    $entries=@(Get-ArrayValue (Get-PropertyValue $assets 'payloads'))
    if ($entries.Count -eq 0) { $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw 'Kext asset manifest contains no staged payloads.' }
    Write-DevintoshStepLog $step "Loaded $($entries.Count) staged kext payload(s)." 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Inspecting kext bundle metadata and payload integrity'
    $metadata=[System.Collections.Generic.List[object]]::new(); $bundleNames=@{}
    foreach ($entry in $entries) {
        $item=Resolve-KextBundleMetadata -StageRoot $stageRoot -Entry $entry
        $key=$item.bundlePath.ToLowerInvariant()
        if ($bundleNames.ContainsKey($key)) { $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw "Duplicate kext BundlePath '$($item.bundlePath)' detected." }
        $bundleNames[$key]=$true; [void]$metadata.Add($item)
    }
    Write-DevintoshStepLog $step "Validated $($metadata.Count) kext bundle(s), including manifest payload hashes and Info.plist executable paths." 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Validating dependency-safe order and activation policy'
    $ordered=[System.Collections.Generic.List[object]]::new()
    foreach ($entry in $entries) {
        $item=@($metadata | Where-Object {$_.id -eq [string](Get-PropertyValue $entry 'id')})
        if ($item.Count -ne 1) { $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw "Unable to correlate staged kext '$([string](Get-PropertyValue $entry 'id'))' with its metadata." }
        [void]$ordered.Add($item[0])
    }
    $seen=@{}
    foreach ($item in $ordered) {
        foreach ($dependency in @($item.dependencies)) {
            if (-not $seen.ContainsKey([string]$dependency)) { $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE; throw "Kext '$($item.id)' appears before its declared dependency '$dependency'." }
        }
        $seen[$item.id]=$true
    }
    $disabled=@($ordered | Where-Object {$_.requiresValidation} | ForEach-Object {$_.id})
    if ($disabled.Count -gt 0) { Write-DevintoshLog 'WARN' "Validation-required kexts will be present but disabled: $($disabled -join ', ')." }
    Write-DevintoshStepLog $step 'Kext order and validation policy passed.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Loading OpenCore Kernel Add configuration'
    $xml=New-Object System.Xml.XmlDocument; $xml.PreserveWhitespace=$true; $xml.Load($configPath)
    $root=[System.Xml.XmlElement]$xml.DocumentElement.SelectSingleNode('/plist/dict')
    if ($null -eq $root) { $EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE; throw 'Generated config.plist has an invalid plist root.' }
    Write-DevintoshStepLog $step 'OpenCore configuration loaded.' 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Composing deterministic Kernel Add entries'
    Set-KernelAdd -Root $root -Entries @($ordered)
    if (-not (Test-Path -LiteralPath $script:BackupRoot)) { New-Item -ItemType Directory -Path $script:BackupRoot -Force | Out-Null }
    $backupStamp=(Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff',[Globalization.CultureInfo]::InvariantCulture)
    $backupPath=Join-Path $script:BackupRoot ("config-kexts-{0}.plist" -f $backupStamp)
    Copy-Item -LiteralPath $configPath -Destination $backupPath -Force
    Add-DevintoshRollbackAction "Restore OpenCore candidate from $backupPath" { if (Test-Path -LiteralPath $backupPath) { Copy-Item -LiteralPath $backupPath -Destination $configPath -Force } }
    $settings=New-Object System.Xml.XmlWriterSettings; $settings.Encoding=New-Object System.Text.UTF8Encoding($false); $settings.Indent=$true
    $writer=[System.Xml.XmlWriter]::Create($configPath,$settings)
    try { $xml.Save($writer) } finally { $writer.Dispose() }
    Write-DevintoshStepLog $step "Kernel/Add composed for $($ordered.Count) kext(s)." 'PASS'

    $step++; Write-DevintoshProgress $step $totalSteps 'Writing kext composition report'
    $report=[ordered]@{
        schemaVersion=1
        generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        sourceAssets='build/opencore/kext-assets.json'
        status=$(if($disabled.Count -gt 0){'NeedsValidation'}else{'Applied'})
        entries=@($ordered | ForEach-Object {[ordered]@{id=$_.id;version=$_.version;bundlePath=$_.bundlePath;executablePath=$_.executablePath;plistPath=$_.plistPath;enabled=$_.enabled;requiresValidation=$_.requiresValidation;dependencies=@($_.dependencies);payloadSha256=$_.payloadSha256}})
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    Write-DevintoshStepLog $step 'Kext composition report written.' 'PASS'

    Complete-DevintoshProgress 'OpenCore kext composition complete'
    exit $script:EXIT_SUCCESS
}
catch {
    if ($EXIT_CODE -eq $script:EXIT_SUCCESS) { $EXIT_CODE=$script:EXIT_GENERAL_FAILURE }
    Write-DevintoshStepLog $step "Kext composition failed: $($_.Exception.Message)" 'FAIL'
    try { Invoke-DevintoshRollback } catch { $EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE }
    exit $EXIT_CODE
}
