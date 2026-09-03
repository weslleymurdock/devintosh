#requires -Version 5.1
<##
.SYNOPSIS
    Imports a read-only native macOS validation bundle into the Devintosh build state.
.DESCRIPTION
    Validates the bundle manifest and SHA-256 evidence hashes, copies the immutable evidence
    into build/opencore/macos-validation, and derives capability validation reports only from
    observed evidence. No SMBIOS identifiers, GPU spoofing, ACPI patches, USB maps, audio
    layouts, network settings or OpenCore mutations are generated.

    The importer deliberately requires explicit validation markers for runtime capabilities.
    Merely seeing a device in System Information is evidence, not proof of compatibility.

.PARAMETER BundlePath
    Path to the extracted validation bundle directory or its ZIP archive.

.PARAMETER Force
    Replaces an existing imported validation bundle after creating a rollback backup.

.EXIT CODES
    0 = Validation evidence imported successfully.
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
param(
    [Parameter(Mandatory)][string]$BundlePath,
    [switch]$Force
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\console.ps1"
. "$PSScriptRoot\lib\logging.ps1"
. "$PSScriptRoot\lib\progress.ps1"
. "$PSScriptRoot\lib\rollback.ps1"

$EXIT_CODE=$script:EXIT_SUCCESS
$step=0
$totalSteps=8
$outputRoot=Join-Path $script:BuildRoot 'opencore'
$destination=Join-Path $outputRoot 'macos-validation'
$reportPath=Join-Path $outputRoot 'macos-validation-report.json'
$backupRoot=Join-Path $script:BackupRoot 'macos-validation'

function Get-PropertyValue { param([AllowNull()][object]$Object,[Parameter(Mandatory)][string]$Name); if($null -eq $Object){return $null}; $p=$Object.PSObject.Properties[$Name]; if($null -eq $p){return $null}; return $p.Value }
function Get-ArraySafe { param([AllowNull()]$Value); if($null -eq $Value){return @()}; return @($Value) }
function Resolve-Bundle {
    param([Parameter(Mandatory)][string]$Path)
    $resolved=(Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    if(Test-Path -LiteralPath $resolved -PathType Container){ return [pscustomobject]@{Root=$resolved; Temporary=$false} }
    if([IO.Path]::GetExtension($resolved) -ine '.zip'){ throw "BundlePath must be a directory or .zip archive: $resolved" }
    $temp=Join-Path ([IO.Path]::GetTempPath()) ("devintosh-macos-validation-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    Expand-Archive -LiteralPath $resolved -DestinationPath $temp -Force
    $dirs=@(Get-ChildItem -LiteralPath $temp -Directory)
    if($dirs.Count -eq 1){$root=$dirs[0].FullName}else{$root=$temp}
    return [pscustomobject]@{Root=$root; Temporary=$true}
}
function Read-JsonFile { param([Parameter(Mandatory)][string]$Path); return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
function Test-Sha256Manifest {
    param([Parameter(Mandatory)][string]$Root)
    $sumPath=Join-Path $Root 'SHA256SUMS'
    if(-not(Test-Path -LiteralPath $sumPath -PathType Leaf)){throw "SHA256SUMS is missing: $sumPath"}
    $failures=[System.Collections.Generic.List[string]]::new()
    foreach($line in @(Get-Content -LiteralPath $sumPath -Encoding UTF8)){
        if([string]::IsNullOrWhiteSpace($line)){continue}
        $parts=$line -split '\s+',2
        if($parts.Count -ne 2){[void]$failures.Add("Malformed SHA-256 entry: $line");continue}
        $expected=$parts[0].ToLowerInvariant(); $relative=$parts[1].TrimStart('*').Replace('/','\')
        $file=Join-Path $Root $relative
        if(-not(Test-Path -LiteralPath $file -PathType Leaf)){[void]$failures.Add("Missing hashed evidence: $relative");continue}
        $actual=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        if($actual -ne $expected){[void]$failures.Add("SHA-256 mismatch: $relative")}
    }
    return @($failures)
}
function Copy-EvidenceTransactional {
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Destination)
    if(Test-Path -LiteralPath $Destination -PathType Container){
        if(-not $Force){$script:EXIT_CODE=$script:EXIT_VALIDATION_FAILURE;throw "Imported macOS validation evidence already exists. Use -Force to replace it: $Destination"}
        if(-not(Test-Path -LiteralPath $backupRoot -PathType Container)){New-Item -ItemType Directory -Path $backupRoot -Force|Out-Null}
        $stamp=(Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff',[Globalization.CultureInfo]::InvariantCulture)
        $backup=Join-Path $backupRoot "bundle-$stamp"
        Copy-Item -LiteralPath $Destination -Destination $backup -Recurse -Force
        Add-DevintoshRollbackAction -Name 'Restore previous macOS validation evidence' -Action { if(Test-Path -LiteralPath $Destination -PathType Container){Remove-Item -LiteralPath $Destination -Recurse -Force}; Copy-Item -LiteralPath $backup -Destination $Destination -Recurse -Force }
        Remove-Item -LiteralPath $Destination -Recurse -Force
    } else {
        Add-DevintoshRollbackAction -Name 'Remove imported macOS validation evidence' -Action { if(Test-Path -LiteralPath $Destination -PathType Container){Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue} }
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
}
function Write-ReportTransactional {
    param([Parameter(Mandatory)]$Report)
    if(Test-Path -LiteralPath $reportPath -PathType Leaf){
        if(-not $Force){$script:EXIT_CODE=$script:EXIT_VALIDATION_FAILURE;throw "macOS validation report already exists. Use -Force to replace it: $reportPath"}
        if(-not(Test-Path -LiteralPath $backupRoot -PathType Container)){New-Item -ItemType Directory -Path $backupRoot -Force|Out-Null}
        $stamp=(Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff',[Globalization.CultureInfo]::InvariantCulture); $backup=Join-Path $backupRoot "report-$stamp.json"; Copy-Item -LiteralPath $reportPath -Destination $backup -Force
        Add-DevintoshRollbackAction -Name 'Restore previous macOS validation report' -Action {Copy-Item -LiteralPath $backup -Destination $reportPath -Force}
    } else { Add-DevintoshRollbackAction -Name 'Remove new macOS validation report' -Action {if(Test-Path -LiteralPath $reportPath -PathType Leaf){Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue}} }
    $temp="$reportPath.tmp"; try{$Report|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $temp -Encoding UTF8;Move-Item -LiteralPath $temp -Destination $reportPath -Force}catch{if(Test-Path -LiteralPath $temp -PathType Leaf){Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue};throw}
}
function Get-ExplicitRuntimeValidation {
    param([Parameter(Mandatory)][string]$Root)
    $check=Join-Path $Root 'VALIDATION-CHECKLIST.md'
    $results=[ordered]@{gpu=$false;smbios=$false;acpi=$false;usb=$false;network=$false;audio=$false;kexts=$false}
    $marker=Join-Path $Root 'validation-results.json'
    if(Test-Path -LiteralPath $marker -PathType Leaf){
        try{
            $data=Read-JsonFile $marker
            foreach($key in @($results.Keys)){
                $value=Get-PropertyValue $data $key
                if($null -ne $value){$results[$key]=([string]$value).Trim().ToLowerInvariant() -eq 'validated' -or [bool]$value}
            }
        }catch{throw "validation-results.json is malformed: $($_.Exception.Message)"}
    }
    return [pscustomobject]$results
}
try{
    Start-DevintoshTransaction
    $step++;Write-DevintoshProgress $step $totalSteps 'Checking runtime and validation bundle'
    if(-not(Test-IsAdministrator)){$EXIT_CODE=$script:EXIT_INSUFFICIENT_PRIVILEGES;throw 'Administrator privileges are required.'}
    if(-not(Test-Path -LiteralPath $BundlePath)){ $EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND;throw "Validation bundle was not found: $BundlePath" }
    $resolved=Resolve-Bundle $BundlePath
    Add-DevintoshRollbackAction -Name 'Remove temporary extracted validation bundle' -Action {if($resolved.Temporary -and (Test-Path -LiteralPath $resolved.Root -PathType Container)){Remove-Item -LiteralPath $resolved.Root -Recurse -Force -ErrorAction SilentlyContinue}}
    Write-DevintoshStepLog $step 'Validation bundle is accessible.' 'PASS'

    $step++;Write-DevintoshProgress $step $totalSteps 'Checking manifest schema and privacy policy'
    $manifestPath=Join-Path $resolved.Root 'manifest.json'
    if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){ $EXIT_CODE=$script:EXIT_VALIDATION_FAILURE;throw 'manifest.json is missing from the validation bundle.' }
    $manifest=Read-JsonFile $manifestPath
    if([int](Get-PropertyValue $manifest 'schemaVersion') -ne 1){$EXIT_CODE=$script:EXIT_VALIDATION_FAILURE;throw 'Unsupported macOS validation manifest schema.'}
    if(-not [bool](Get-PropertyValue $manifest 'readOnly')){$EXIT_CODE=$script:EXIT_VALIDATION_FAILURE;throw 'Validation bundle is not marked read-only.'}
    if(-not [bool](Get-PropertyValue $manifest 'privacyRedacted')){$EXIT_CODE=$script:EXIT_VALIDATION_FAILURE;throw 'Validation bundle is not marked privacy-redacted.'}
    Write-DevintoshStepLog $step 'Manifest schema and privacy requirements passed.' 'PASS'

    $step++;Write-DevintoshProgress $step $totalSteps 'Verifying SHA-256 evidence integrity'
    $hashFailures=@(Test-Sha256Manifest $resolved.Root)
    if($hashFailures.Count -gt 0){$EXIT_CODE=$script:EXIT_ASSET_INTEGRITY_FAILURE;throw ($hashFailures -join '; ')}
    Write-DevintoshStepLog $step 'All evidence files match SHA-256 manifest.' 'PASS'

    $step++;Write-DevintoshProgress $step $totalSteps 'Checking evidence categories'
    $requiredEvidence=@('system_profiler.txt','hardware.txt','displays.txt','usb.txt','audio.txt','network.txt','acpi.txt','usb-ioreg.txt','pci-ioreg.txt','kexts.txt','diskutil.txt','nvram.txt','sysctl.txt','metal-observation.txt','boot-args.txt')
    $missing=@($requiredEvidence|Where-Object{-not(Test-Path -LiteralPath (Join-Path $resolved.Root ('evidence\'+$_)) -PathType Leaf)})
    if($missing.Count -gt 0){$EXIT_CODE=$script:EXIT_VALIDATION_FAILURE;throw "Validation bundle is incomplete. Missing evidence: $($missing -join ', ')"}
    Write-DevintoshStepLog $step 'Required evidence categories are present.' 'PASS'

    $step++;Write-DevintoshProgress $step $totalSteps 'Evaluating explicit runtime validation markers'
    $runtime=Get-ExplicitRuntimeValidation $resolved.Root
    $validatedKeys=@($runtime.PSObject.Properties|Where-Object{$_.Value -eq $true}|ForEach-Object{$_.Name})
    $pendingKeys=@($runtime.PSObject.Properties|Where-Object{$_.Value -ne $true}|ForEach-Object{$_.Name})
    Write-DevintoshLog 'INFO' "Explicitly validated capabilities: $($validatedKeys -join ', ')."
    Write-DevintoshLog 'INFO' "Capabilities still requiring runtime validation: $($pendingKeys -join ', ')."
    Write-DevintoshStepLog $step 'Runtime validation markers evaluated without inferring compatibility from inventory.' 'PASS'

    $step++;Write-DevintoshProgress $step $totalSteps 'Importing immutable macOS evidence transactionally'
    Copy-EvidenceTransactional -Source $resolved.Root -Destination $destination
    Write-DevintoshStepLog $step 'macOS validation evidence imported transactionally.' 'PASS'

    $step++;Write-DevintoshProgress $step $totalSteps 'Generating capability validation report'
    $capabilities=[ordered]@{}
    foreach($key in @($runtime.PSObject.Properties.Name)){
        $capabilities[$key]=[pscustomobject]@{status=if($runtime.$key){'Validated'}else{'NeedsValidation'}; evidenceRoot='build/opencore/macos-validation'; explicitlyValidated=[bool]$runtime.$key}
    }
    $overall=if($pendingKeys.Count -eq 0){'Validated'}else{'NeedsValidation'}
    $report=[ordered]@{
        schemaVersion=1
        generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)
        status=$overall
        sourceBundle='native-macos-validation'
        manifest=$manifest
        evidenceIntegrity='SHA256Verified'
        capabilities=[pscustomobject]$capabilities
        validatedCapabilities=$validatedKeys
        pendingCapabilities=$pendingKeys
        applied=$false
        intentionallyNotGenerated=@('SMBIOS unique identifiers','GPU spoofing or DeviceProperties','ACPI patches or SSDTs','USB port maps','Audio layout IDs or routing','Network interface configuration','Any hardware-specific mutation')
        generatedArtifacts=@('build/opencore/macos-validation','build/opencore/macos-validation-report.json')
    }
    Write-ReportTransactional ([pscustomobject]$report)
    Write-DevintoshStepLog $step 'macOS validation report written transactionally.' 'PASS'

    $step++;Write-DevintoshProgress $step $totalSteps 'Finalizing macOS validation stage'
    Complete-DevintoshTransaction
    Complete-DevintoshProgress 'macOS validation evidence import complete'
    $EXIT_CODE=$script:EXIT_SUCCESS
}
catch{
    Write-DevintoshLog 'ERROR' "macOS validation stage failed: $($_.Exception.Message)"
    try{$ok=Invoke-DevintoshRollback;if(-not $ok){$EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE}}catch{$EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE}
    if($EXIT_CODE -eq $script:EXIT_SUCCESS){$EXIT_CODE=$script:EXIT_GENERAL_FAILURE}
}
exit $EXIT_CODE
