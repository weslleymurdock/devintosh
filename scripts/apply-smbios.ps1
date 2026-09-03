#requires -Version 5.1
<#
.SYNOPSIS
    Applies an explicitly validated SMBIOS selection to config.plist.
.DESCRIPTION
    Hardware-agnostic SMBIOS application stage. The script never chooses a Mac model,
    generates identifiers, or persists identity data in source control. It consumes an
    explicit selection manifest, requires validated=true, backs up config.plist, applies
    the five PlatformInfo/Generic identity fields transactionally, and gates the commit
    on the pinned OpenCore 1.0.7 ocvalidate stage.

    A selection manifest is expected to be local/generated state and must not be committed.

.PARAMETER SelectionPath
    Path to a local validated SMBIOS selection manifest.

.PARAMETER Force
    Allows replacement of an existing SMBIOS identity in config.plist after validation.

.EXIT CODES
    0 = SMBIOS applied and validated successfully.
    1 = General failure.
    2 = Validation failure.
    3 = Administrator privileges are required.
    4 = Required resource was not found.
    5 = Automatic rollback failed.
    6 = External dependency failure.
    7 = Generated artifact integrity failure.
    8 = Unsupported configuration.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SelectionPath,
    [switch]$Force
)

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
$configPath = Join-Path $script:BuildRoot 'efi\EFI\OC\config.plist'
$resolutionPath = Join-Path $outputRoot 'smbios-resolution.json'
$reportPath = Join-Path $outputRoot 'smbios-application-report.json'
$backupRoot = Join-Path $script:BackupRoot 'smbios'

function Get-Prop {
    param([AllowNull()][object]$Object,[Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Read-Json {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required JSON file not found: $Path" }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-PlistDictionary {
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Root,[Parameter(Mandatory)][string[]]$Path)
    $current = $Root
    foreach ($name in $Path) {
        $keys = @($current.ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.Name -eq 'key' -and $_.InnerText -eq $name })
        if ($keys.Count -gt 1) { throw "Duplicate plist key: $name" }
        if ($keys.Count -eq 0) {
            $key = $current.OwnerDocument.CreateElement('key')
            $key.InnerText = $name
            [void]$current.AppendChild($key)
            $dict = $current.OwnerDocument.CreateElement('dict')
            [void]$current.AppendChild($dict)
            $current = $dict
        } else {
            $value = $keys[0].NextSibling
            while ($null -ne $value -and $value.NodeType -ne 'Element') { $value = $value.NextSibling }
            if ($null -eq $value -or $value.Name -ne 'dict') { throw "Plist path '$name' is not a dictionary." }
            $current = [System.Xml.XmlElement]$value
        }
    }
    return $current
}

function Set-PlistValue {
    param(
        [Parameter(Mandatory)][System.Xml.XmlElement]$Dict,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('string','data')][string]$Type,
        [Parameter(Mandatory)][string]$Value
    )
    $keys = @($Dict.ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.Name -eq 'key' -and $_.InnerText -eq $Name })
    if ($keys.Count -gt 1) { throw "Duplicate plist key: $Name" }
    if ($keys.Count -eq 0) {
        $key = $Dict.OwnerDocument.CreateElement('key')
        $key.InnerText = $Name
        [void]$Dict.AppendChild($key)
    } else {
        $key = $keys[0]
    }
    $old = $key.NextSibling
    while ($null -ne $old -and $old.NodeType -ne 'Element') { $old = $old.NextSibling }
    if ($null -ne $old) { [void]$Dict.RemoveChild($old) }
    $node = $Dict.OwnerDocument.CreateElement($Type)
    $node.InnerText = $Value
    [void]$key.ParentNode.InsertAfter($node,$key)
}

function Test-Selection {
    param([Parameter(Mandatory)]$Selection)
    if ((Get-Prop $Selection 'validated') -ne $true) { throw 'SMBIOS selection must explicitly declare validated=true.' }
    $required = @('productName','systemSerialNumber','mlb','systemUuid','rom')
    foreach ($name in $required) {
        $value = [string](Get-Prop $Selection $name)
        if ([string]::IsNullOrWhiteSpace($value)) { throw "Validated SMBIOS selection is missing '$name'." }
    }
    $uuid = [string](Get-Prop $Selection 'systemUuid')
    if ($uuid -notmatch '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$') { throw "Invalid SystemUUID format: $uuid" }
    $rom = ([string](Get-Prop $Selection 'rom')).Replace(':','').Replace('-','')
    if ($rom -notmatch '^[0-9A-Fa-f]{12}$') { throw 'ROM must contain exactly 6 bytes (12 hexadecimal characters).' }
    if ([string](Get-Prop $Selection 'source') -eq '') { throw 'Validated SMBIOS selection must identify its validation source.' }
    return $rom.ToUpperInvariant()
}

function Invoke-OpenCoreValidation {
    & (Join-Path $PSScriptRoot 'validate-opencore.ps1')
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "ocvalidate rejected config.plist with exit code $code." }
}

try {
    Start-DevintoshTransaction

    $step++
    Write-DevintoshProgress $step $totalSteps 'Checking SMBIOS application prerequisites'
    if (-not (Test-IsAdministrator)) { $EXIT_CODE=$script:EXIT_INSUFFICIENT_PRIVILEGES; throw 'Administrator privileges are required.' }
    if (-not (Test-Path -LiteralPath $SelectionPath -PathType Leaf)) { $EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND; throw "SMBIOS selection manifest not found: $SelectionPath" }
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { $EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND; throw "OpenCore config.plist not found: $configPath" }
    Write-DevintoshStepLog $step 'SMBIOS application prerequisites are available.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Loading and validating explicit SMBIOS selection'
    $selection = Read-Json $SelectionPath
    $rom = Test-Selection $selection
    if (Test-Path -LiteralPath $resolutionPath -PathType Leaf) {
        $resolution = Read-Json $resolutionPath
        $candidateNames = @((Get-Prop $resolution 'candidates') | ForEach-Object { [string](Get-Prop $_ 'productName') })
        $productName = [string](Get-Prop $selection 'productName')
        if ($candidateNames.Count -gt 0 -and $candidateNames -notcontains $productName) {
            $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE
            throw "Selected SMBIOS product '$productName' is not present in the current SMBIOS resolution candidates."
        }
    }
    Write-DevintoshStepLog $step 'Explicit SMBIOS identity passed local validation requirements.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Loading OpenCore config and checking existing identity'
    $document = New-Object System.Xml.XmlDocument
    $document.PreserveWhitespace = $true
    $document.Load($configPath)
    $plistRoot = $document.SelectSingleNode('/plist/dict')
    if ($null -eq $plistRoot) { $EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE; throw 'Invalid OpenCore config.plist root.' }
    $generic = Get-PlistDictionary ([System.Xml.XmlElement]$plistRoot) @('PlatformInfo','Generic')
    $existingProduct = @($generic.ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.Name -eq 'key' -and $_.InnerText -eq 'SystemProductName' })
    if ($existingProduct.Count -gt 0 -and -not $Force) {
        $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE
        throw 'config.plist already contains SystemProductName. Use -Force only with an explicitly validated replacement.'
    }
    Write-DevintoshStepLog $step 'OpenCore config.plist is structurally available for transactional application.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Creating transactional SMBIOS backup'
    if (-not (Test-Path -LiteralPath $backupRoot -PathType Container)) { [void](New-Item -ItemType Directory -Path $backupRoot -Force) }
    $stamp=(Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff',[Globalization.CultureInfo]::InvariantCulture)
    $backupPath=Join-Path $backupRoot ("config-{0}.plist" -f $stamp)
    Copy-Item -LiteralPath $configPath -Destination $backupPath -Force
    Add-DevintoshRollbackAction -Name 'Restore previous config.plist after SMBIOS application failure' -Action {
        Copy-Item -LiteralPath $backupPath -Destination $configPath -Force
    }
    Write-DevintoshStepLog $step "Transactional backup created at $backupPath." 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Applying validated SMBIOS identity'
    Set-PlistValue $generic 'SystemProductName' 'string' ([string](Get-Prop $selection 'productName'))
    Set-PlistValue $generic 'SystemSerialNumber' 'string' ([string](Get-Prop $selection 'systemSerialNumber'))
    Set-PlistValue $generic 'MLB' 'string' ([string](Get-Prop $selection 'mlb'))
    Set-PlistValue $generic 'SystemUUID' 'string' ([string](Get-Prop $selection 'systemUuid')).ToUpperInvariant()
    Set-PlistValue $generic 'ROM' 'data' $rom
    $temp="$configPath.smbios.tmp"
    try {
        $document.Save($temp)
        Move-Item -LiteralPath $temp -Destination $configPath -Force
    } finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
    Write-DevintoshStepLog $step 'Validated SMBIOS identity applied atomically to config.plist.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Running pinned OpenCore validation gate'
    Invoke-OpenCoreValidation
    Write-DevintoshStepLog $step 'Pinned OpenCore 1.0.7 ocvalidate accepted the SMBIOS-modified config.plist.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Writing SMBIOS application report'
    if (-not (Test-Path -LiteralPath $outputRoot -PathType Container)) { [void](New-Item -ItemType Directory -Path $outputRoot -Force) }
    $report=[ordered]@{
        schemaVersion=1
        generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        status='AppliedAndValidated'
        selectionPath=$SelectionPath
        productName=[string](Get-Prop $selection 'productName')
        appliedFields=@('SystemProductName','SystemSerialNumber','MLB','SystemUUID','ROM')
        uniqueIdentifiersPersistedInRepository=$false
        validation='OpenCore 1.0.7 ocvalidate'
        generatedArtifacts=@('build/opencore/smbios-application-report.json')
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    Add-DevintoshRollbackAction -Name 'Remove SMBIOS application report' -Action { if (Test-Path -LiteralPath $reportPath -PathType Leaf) { Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue } }
    Write-DevintoshStepLog $step 'SMBIOS application report written.' 'PASS'

    $step++
    Write-DevintoshProgress $step $totalSteps 'Committing SMBIOS transaction'
    Complete-DevintoshTransaction
    Complete-DevintoshProgress 'SMBIOS application complete'
    $EXIT_CODE=$script:EXIT_SUCCESS
}
catch {
    Write-DevintoshLog 'ERROR' "SMBIOS application failed: $($_.Exception.Message)"
    try {
        $rollbackOk=Invoke-DevintoshRollback
        if (-not $rollbackOk) { $EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE }
    } catch { $EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE }
    if ($EXIT_CODE -eq $script:EXIT_SUCCESS) { $EXIT_CODE=$script:EXIT_GENERAL_FAILURE }
}
exit $EXIT_CODE
