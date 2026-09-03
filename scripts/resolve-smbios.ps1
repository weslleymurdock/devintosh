#requires -Version 5.1
<#
.SYNOPSIS
    Resolves SMBIOS capability profiles and candidates without generating identities.
.DESCRIPTION
    Hardware-agnostic SMBIOS stage. SMBIOS candidates are declarative profile data.
    This script never generates or persists SystemProductName, SystemSerialNumber, MLB,
    SystemUUID, or ROM. It reports NeedsProfile or NeedsValidation and leaves config.plist
    unchanged. Generated state is transactional and uses the shared rollback mechanism.
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
$reportPath = Join-Path $outputRoot 'smbios-resolution.json'
$backupRoot = Join-Path $script:BackupRoot 'smbios'

function Get-PropertyValue {
    param([AllowNull()][object]$Object,[Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}
function Get-ArraySafe { param([AllowNull()]$Value); if ($null -eq $Value) { return @() }; return @($Value) }
function Read-JsonFile { param([Parameter(Mandatory)][string]$Path); if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required JSON file not found: $Path" }; return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
function Test-StringEquals {
    param([AllowNull()]$Actual,[AllowNull()]$Expected)
    if ($null -eq $Actual -or $null -eq $Expected) { return $false }
    return ([string]$Actual).Trim().Equals(([string]$Expected).Trim(),[StringComparison]::OrdinalIgnoreCase)
}
function Test-SmbiosProfileMatch {
    param([Parameter(Mandatory)]$Hardware,[Parameter(Mandatory)]$Profile)
    $rule=Get-PropertyValue $Profile 'match'; if ($null -eq $rule) { return $false }
    $cpu=Get-PropertyValue $Hardware 'cpu'; $platform=Get-PropertyValue $Hardware 'platform'
    $expected=Get-PropertyValue $rule 'cpuVendor'; if ($null -ne $expected -and -not(Test-StringEquals (Get-PropertyValue $cpu 'Manufacturer') $expected)){return $false}
    $expected=Get-PropertyValue $rule 'cpuName'; if ($null -ne $expected -and -not(Test-StringEquals (Get-PropertyValue $cpu 'Name') $expected)){return $false}
    $regex=Get-PropertyValue $rule 'cpuNameRegex'; if ($null -ne $regex -and [string](Get-PropertyValue $cpu 'Name') -notmatch [string]$regex){return $false}
    $expected=Get-PropertyValue $rule 'platformManufacturer'; if ($null -ne $expected -and -not(Test-StringEquals (Get-PropertyValue $platform 'Manufacturer') $expected)){return $false}
    $expected=Get-PropertyValue $rule 'platformModel'; if ($null -ne $expected -and -not(Test-StringEquals (Get-PropertyValue $platform 'Model') $expected)){return $false}
    $regex=Get-PropertyValue $rule 'platformModelRegex'; if ($null -ne $regex -and [string](Get-PropertyValue $platform 'Model') -notmatch [string]$regex){return $false}
    return $true
}
function Get-SmbiosProfiles {
    $root=Join-Path $script:RepoRoot 'config\hardware\smbios'; $result=[System.Collections.Generic.List[object]]::new()
    if(-not(Test-Path -LiteralPath $root -PathType Container)){return @()}
    foreach($file in @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue)){
        try{$profile=Read-JsonFile $file.FullName;$caps=Get-PropertyValue $profile 'capabilities';if($null -ne(Get-PropertyValue $profile 'id') -and $null -ne(Get-PropertyValue $profile 'match') -and $null -ne$caps -and [bool](Get-PropertyValue $caps 'smbios')){[void]$result.Add($profile)}}
        catch{Write-DevintoshLog 'WARN' "Ignoring invalid SMBIOS profile $($file.FullName): $($_.Exception.Message)"}
    }
    return @($result.ToArray())
}
function Get-Candidates {
    param([AllowNull()][object[]]$Profiles)
    $result=[System.Collections.Generic.List[object]]::new()
    foreach($profile in @(Get-ArraySafe $Profiles)){
        $smbios=Get-PropertyValue (Get-PropertyValue $profile 'opencore') 'smbios';if($null -eq$smbios){continue}
        $id=[string](Get-PropertyValue $profile 'id');$policy=[string](Get-PropertyValue $smbios 'policy');$reason=[string](Get-PropertyValue $smbios 'reason')
        foreach($candidate in @(Get-ArraySafe (Get-PropertyValue $smbios 'candidates'))){
            $name=[string](Get-PropertyValue $candidate 'productName');if([string]::IsNullOrWhiteSpace($name)){continue}
            [void]$result.Add([pscustomobject]@{profileId=$id;productName=$name;confidence=[string](Get-PropertyValue $candidate 'confidence');requiresValidation=(($policy -eq 'validation-required') -or [bool](Get-PropertyValue $candidate 'requiresValidation'));rationale=[string](Get-PropertyValue $candidate 'rationale');profileReason=$reason})
        }
    }
    return @($result.ToArray())
}
function Write-ReportTransactional {
    param([Parameter(Mandatory)]$Report)
    if(-not(Test-Path -LiteralPath $outputRoot -PathType Container)){[void](New-Item -ItemType Directory -Path $outputRoot -Force)}
    if(-not(Test-Path -LiteralPath $backupRoot -PathType Container)){[void](New-Item -ItemType Directory -Path $backupRoot -Force)}
    if(Test-Path -LiteralPath $reportPath -PathType Leaf){
        $stamp=(Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff',[Globalization.CultureInfo]::InvariantCulture);$backup=Join-Path $backupRoot ("smbios-resolution-{0}.json" -f $stamp);Copy-Item -LiteralPath $reportPath -Destination $backup -Force
        Add-DevintoshRollbackAction -Name 'Restore previous SMBIOS resolution report' -Action { Copy-Item -LiteralPath $backup -Destination $reportPath -Force }
    }else{Add-DevintoshRollbackAction -Name 'Remove newly created SMBIOS resolution report' -Action {if(Test-Path -LiteralPath $reportPath -PathType Leaf){Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue}}}
    $temp="$reportPath.tmp"
    try{$Report|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $temp -Encoding UTF8;Move-Item -LiteralPath $temp -Destination $reportPath -Force}catch{if(Test-Path -LiteralPath $temp -PathType Leaf){Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue};throw}
}
try{
    Start-DevintoshTransaction
    $step++;Write-DevintoshProgress $step $totalSteps 'Checking runtime and hardware inventory';if(-not(Test-IsAdministrator)){$EXIT_CODE=$script:EXIT_INSUFFICIENT_PRIVILEGES;throw 'Administrator privileges are required.'};if(-not(Test-Path -LiteralPath $hardwarePath -PathType Leaf)){$EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND;throw "Run configure-opencore-hardware.ps1 first: $hardwarePath"};Write-DevintoshStepLog $step 'Runtime and live hardware inventory are available.' 'PASS'
    $step++;Write-DevintoshProgress $step $totalSteps 'Loading detected hardware and SMBIOS profiles';$hardware=Read-JsonFile $hardwarePath;$profiles=@(Get-SmbiosProfiles);Write-DevintoshLog 'INFO' "SMBIOS profiles discovered: $($profiles.Count).";Write-DevintoshStepLog $step 'SMBIOS profile catalog loaded without manual identity input.' 'PASS'
    $step++;Write-DevintoshProgress $step $totalSteps 'Matching SMBIOS capability profiles';$matched=[System.Collections.Generic.List[object]]::new();foreach($profile in @(Get-ArraySafe $profiles)){if(Test-SmbiosProfileMatch $hardware $profile){[void]$matched.Add($profile)}};$matchedIds=@($matched|ForEach-Object{[string](Get-PropertyValue $_ 'id')}|Select-Object -Unique);Write-DevintoshLog 'INFO' "Matched SMBIOS profiles: $($matchedIds -join ', ').";Write-DevintoshStepLog $step "SMBIOS capability matching completed: $($matched.Count) profile(s)." 'PASS'
    $step++;Write-DevintoshProgress $step $totalSteps 'Resolving declarative SMBIOS candidates';$candidates=@(Get-Candidates -Profiles $matched.ToArray());$unique=@($candidates|Group-Object productName|ForEach-Object{[pscustomobject]@{productName=[string]$_.Name;profiles=@($_.Group|ForEach-Object{$_.profileId}|Select-Object -Unique);requiresValidation=@($_.Group|Where-Object{$_.requiresValidation}).Count -gt 0;confidence=@($_.Group|ForEach-Object{$_.confidence}|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Select-Object -Unique);rationale=@($_.Group|ForEach-Object{$_.rationale}|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Select-Object -Unique)}});Write-DevintoshLog 'INFO' "SMBIOS candidates resolved: $($unique.Count).";Write-DevintoshStepLog $step 'SMBIOS candidate resolution completed without fabricating an identity.' 'PASS'
    $step++;Write-DevintoshProgress $step $totalSteps 'Applying SMBIOS safety policy';$status='NeedsProfile';$unresolved=@('smbios');$warnings=@();if($matched.Count -gt 0){$status='NeedsValidation';$unresolved=@();$warnings+= 'SMBIOS identity is intentionally not generated or persisted automatically.';$warnings+='SystemProductName, SystemSerialNumber, MLB, SystemUUID, and ROM remain unset until a separately validated stage permits them.';if($unique.Count -eq 0){$warnings+='Matched SMBIOS capability profiles provide no product candidate; external validation is required.'}};$report=[ordered]@{schemaVersion=1;generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o');sourceHardware='build/opencore/hardware-detected.json';sourceProfiles='config/hardware/smbios';status=$status;matchedProfiles=@($matchedIds);candidates=@($unique);applied=$false;unresolvedCapabilities=@($unresolved);warnings=@($warnings);intentionallyNotGenerated=@('SystemProductName','SystemSerialNumber','MLB','SystemUUID','ROM');generatedArtifacts=@('build/opencore/smbios-resolution.json')};Write-DevintoshStepLog $step "SMBIOS safety policy completed: $status." $(if($status -eq 'NeedsProfile'){'WARN'}else{'PASS'})
    $step++;Write-DevintoshProgress $step $totalSteps 'Writing transactional SMBIOS resolution report';Write-ReportTransactional ([pscustomobject]$report);Write-DevintoshStepLog $step 'SMBIOS resolution report written transactionally.' 'PASS'
    $step++;Write-DevintoshProgress $step $totalSteps 'Finalizing hardware-agnostic SMBIOS resolution';Write-DevintoshLog 'INFO' 'No SMBIOS unique identifiers or guessed Mac model were written to config.plist.';Complete-DevintoshTransaction;Complete-DevintoshProgress 'SMBIOS resolution complete';$EXIT_CODE=$script:EXIT_SUCCESS
}catch{Write-DevintoshLog 'ERROR' "SMBIOS resolution failed: $($_.Exception.Message)";try{$ok=Invoke-DevintoshRollback;if(-not$ok){$EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE}}catch{$EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE};if($EXIT_CODE -eq $script:EXIT_SUCCESS){$EXIT_CODE=$script:EXIT_GENERAL_FAILURE}}
exit $EXIT_CODE
