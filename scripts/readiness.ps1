#requires -Version 5.1
<#
.SYNOPSIS
    Evaluates conservative Devintosh/OpenCore readiness.
.DESCRIPTION
    Consumes Windows-side resolution reports, final ocvalidate output, and optional
    native macOS validation evidence. Native runtime capabilities are promoted only
    by explicit Validated markers from macOS validation; device presence is never
    treated as proof. The script is report-only.
.PARAMETER Force
    Replaces an existing readiness report after creating a rollback backup.
#>
[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot\lib\common.ps1"
. "$PSScriptRoot\lib\console.ps1"
. "$PSScriptRoot\lib\logging.ps1"
. "$PSScriptRoot\lib\progress.ps1"
. "$PSScriptRoot\lib\rollback.ps1"

$EXIT_CODE=$script:EXIT_SUCCESS
$step=0;$totalSteps=8
$outputRoot=Join-Path $script:BuildRoot 'opencore'
$reportPath=Join-Path $outputRoot 'readiness-report.json'
$backupRoot=Join-Path $script:BackupRoot 'readiness'

function Get-PropertyValue { param([AllowNull()][object]$Object,[Parameter(Mandatory)][string]$Name); if($null -eq $Object){return $null};$p=$Object.PSObject.Properties[$Name];if($null -eq $p){return $null};return $p.Value }
function Get-ArraySafe { param([AllowNull()]$Value);if($null -eq $Value){return @()};return @($Value) }
function Read-Report { param([Parameter(Mandatory)][string]$RelativePath,[bool]$Optional=$false);$p=Join-Path $script:RepoRoot $RelativePath;if(-not(Test-Path -LiteralPath $p -PathType Leaf)){return [pscustomobject]@{path=$RelativePath;exists=$false;valid=$Optional;data=$null;error=if($Optional){$null}else{'Required report was not found.'}}};try{$d=Get-Content -LiteralPath $p -Raw -Encoding UTF8|ConvertFrom-Json;return [pscustomobject]@{path=$RelativePath;exists=$true;valid=$true;data=$d;error=$null}}catch{return [pscustomobject]@{path=$RelativePath;exists=$true;valid=$false;data=$null;error=$_.Exception.Message}} }
function Get-Status { param([AllowNull()]$Report);if($null -eq $Report -or -not $Report.valid -or $null -eq $Report.data){return 'Blocked'};$s=Get-PropertyValue $Report.data 'status';if($null -eq $s){return 'Unknown'};return [string]$s }
function Write-ReportTransactional { param([Parameter(Mandatory)]$Report);if(-not(Test-Path -LiteralPath $outputRoot -PathType Container)){New-Item -ItemType Directory -Path $outputRoot -Force|Out-Null};if(-not(Test-Path -LiteralPath $backupRoot -PathType Container)){New-Item -ItemType Directory -Path $backupRoot -Force|Out-Null};if(Test-Path -LiteralPath $reportPath -PathType Leaf){if(-not $Force){$script:EXIT_CODE=$script:EXIT_VALIDATION_FAILURE;throw "Readiness report already exists. Use -Force to replace it: $reportPath"};$stamp=(Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff',[Globalization.CultureInfo]::InvariantCulture);$backup=Join-Path $backupRoot "readiness-report-$stamp.json";Copy-Item $reportPath $backup -Force;Add-DevintoshRollbackAction -Name 'Restore previous readiness report' -Action {Copy-Item $backup $reportPath -Force}}else{Add-DevintoshRollbackAction -Name 'Remove newly created readiness report' -Action {if(Test-Path -LiteralPath $reportPath -PathType Leaf){Remove-Item $reportPath -Force -ErrorAction SilentlyContinue}}};$temp="$reportPath.tmp";try{$Report|ConvertTo-Json -Depth 30|Set-Content $temp -Encoding UTF8;Move-Item $temp $reportPath -Force}catch{if(Test-Path $temp){Remove-Item $temp -Force -ErrorAction SilentlyContinue};throw} }
function Get-MacValidated { param([AllowNull()]$Report,[Parameter(Mandatory)][string]$Key);if($null -eq $Report -or -not $Report.exists -or -not $Report.valid -or $null -eq $Report.data){return $false};$caps=Get-PropertyValue $Report.data 'capabilities';$cap=Get-PropertyValue $caps $Key;return ($null -ne $cap -and (Get-PropertyValue $cap 'status') -eq 'Validated') }

try {
    Start-DevintoshTransaction
    $step++;Write-DevintoshProgress $step $totalSteps 'Checking readiness prerequisites'
    if(-not(Test-IsAdministrator)){$EXIT_CODE=$script:EXIT_INSUFFICIENT_PRIVILEGES;throw 'Administrator privileges are required.'}
    if(-not(Test-Path -LiteralPath $outputRoot -PathType Container)){$EXIT_CODE=$script:EXIT_TARGET_NOT_FOUND;throw "OpenCore build state was not found: $outputRoot"}
    Write-DevintoshStepLog $step 'Runtime and OpenCore build state are available.' 'PASS'

    $step++;Write-DevintoshProgress $step $totalSteps 'Loading resolution, validation and native macOS evidence'
    $defs=@(
        [pscustomobject]@{key='hardware';path='build/opencore/hardware-detected.json';required=$true},
        [pscustomobject]@{key='hardwareResolution';path='build/opencore/configuration-report.json';required=$true},
        [pscustomobject]@{key='gpu';path='build/opencore/gpu-resolution.json';required=$true},
        [pscustomobject]@{key='smbios';path='build/opencore/smbios-resolution.json';required=$true},
        [pscustomobject]@{key='acpi';path='build/opencore/acpi-resolution.json';required=$true},
        [pscustomobject]@{key='usb';path='build/opencore/usb-resolution.json';required=$true},
        [pscustomobject]@{key='network';path='build/opencore/network-resolution.json';required=$true},
        [pscustomobject]@{key='audio';path='build/opencore/audio-resolution.json';required=$true},
        [pscustomobject]@{key='kextResolution';path='build/opencore/kext-resolution.json';required=$true},
        [pscustomobject]@{key='kextAssets';path='build/opencore/kext-assets.json';required=$true},
        [pscustomobject]@{key='kextComposition';path='build/opencore/kext-composition-report.json';required=$true},
        [pscustomobject]@{key='validation';path='build/opencore/validation-report.json';required=$true},
        [pscustomobject]@{key='macosValidation';path='build/opencore/macos-validation-report.json';required=$false}
    )
    $loaded=[System.Collections.Generic.List[object]]::new();foreach($d in $defs){$r=Read-Report $d.path (-not $d.required);[void]$loaded.Add([pscustomobject]@{key=$d.key;path=$d.path;required=$d.required;exists=$r.exists;valid=$r.valid;data=$r.data;error=$r.error})}
    $mac=@($loaded|Where-Object{$_.key -eq 'macosValidation'})[0]
    if($mac.exists -and -not $mac.valid){throw "Native macOS validation report is malformed: $($mac.path): $($mac.error)"}
    Write-DevintoshStepLog $step 'All readiness inputs were inspected.' 'PASS'

    $step++;Write-DevintoshProgress $step $totalSteps 'Checking report integrity and generated config'
    $blocked=[System.Collections.Generic.List[string]]::new();foreach($i in @($loaded|Where-Object{$_.required})){if(-not$i.exists){[void]$blocked.Add("Missing required report: $($i.path)")}elseif(-not$i.valid){[void]$blocked.Add("Malformed required report: $($i.path): $($i.error)")}}
    $configPath=Join-Path $script:BuildRoot 'efi\EFI\OC\config.plist';if(-not(Test-Path -LiteralPath $configPath -PathType Leaf)){[void]$blocked.Add('Generated OpenCore config.plist is missing.')}
    Write-DevintoshStepLog $step "Input integrity checked: $($blocked.Count) blocking issue(s)." $(if($blocked.Count -eq 0){'PASS'}else{'WARN'})

    $step++;Write-DevintoshProgress $step $totalSteps 'Evaluating effective capability states'
    $keys=@('hardwareResolution','gpu','smbios','acpi','usb','network','audio','kextResolution','kextAssets','kextComposition');$states=[System.Collections.Generic.List[object]]::new()
    foreach($key in $keys){$item=@($loaded|Where-Object{$_.key -eq $key})[0];$status=Get-Status $item;$unresolved=@();if($null -ne $item.data){$unresolved=@(Get-ArraySafe(Get-PropertyValue $item.data 'unresolvedCapabilities'))}
        if($key -in @('gpu','smbios','acpi','usb','network','audio') -and (Get-MacValidated $mac $key)){$status='Validated';$unresolved=@()}
        if($key -eq 'hardwareResolution' -and $mac.exists -and $mac.valid -and (Get-Status $item) -eq 'NeedsValidation'){$status='Resolved';$unresolved=@()}
        if($key -in @('kextResolution','kextAssets') -and (Get-MacValidated $mac 'kexts')){$status='Resolved';$unresolved=@()}
        [void]$states.Add([pscustomobject]@{key=$key;path=$item.path;status=$status;unresolvedCapabilities=$unresolved})
    }
    $needsProfile=@($states|Where-Object{$_.status -eq 'NeedsProfile' -or @($_.unresolvedCapabilities).Count -gt 0});$needsValidation=@($states|Where-Object{$_.status -eq 'NeedsValidation'});$unknown=@($states|Where-Object{$_.status -notin @('Resolved','Validated','Valid','NeedsValidation','NeedsProfile') -and -not($_.key -eq 'kextComposition' -and $_.status -eq 'Applied')})
    foreach($s in $unknown){[void]$blocked.Add("Unknown readiness state '$($s.status)' in $($s.path).")}
    Write-DevintoshLog 'INFO' "Effective capability states: NeedsProfile=$($needsProfile.Count), NeedsValidation=$($needsValidation.Count), Unknown=$($unknown.Count). Native macOS evidence present=$($mac.exists)."
    Write-DevintoshStepLog $step 'Capability evaluation completed without inference.' 'PASS'

    $step++;Write-DevintoshProgress $step $totalSteps 'Evaluating final OpenCore validation'
    $v=@($loaded|Where-Object{$_.key -eq 'validation'})[0];$vs=Get-Status $v;$exit=Get-PropertyValue $v.data 'validatorExitCode';$ver=[string](Get-PropertyValue $v.data 'openCoreVersion');if($vs -ne 'Valid' -or $null -eq $exit -or [int]$exit -ne 0){[void]$blocked.Add('Final ocvalidate report is not valid with exit code 0.')}
    $versionPath=Join-Path $script:RepoRoot 'config\versions\sequoia.json';if(-not(Test-Path $versionPath)){[void]$blocked.Add('Pinned macOS/OpenCore version configuration is missing.')}else{$vc=Get-Content $versionPath -Raw -Encoding UTF8|ConvertFrom-Json;$expected=[string](Get-PropertyValue(Get-PropertyValue $vc 'opencore') 'version');if(-not[string]::IsNullOrWhiteSpace($expected)-and$ver-ne$expected){[void]$blocked.Add("Validation used OpenCore '$ver' but pinned configuration requires '$expected'.")}}
    Write-DevintoshStepLog $step "Final OpenCore validation: $vs; version: $ver." $(if($blocked.Count -eq 0){'PASS'}else{'WARN'})

    $step++;Write-DevintoshProgress $step $totalSteps 'Computing conservative readiness decision'
    $status='Ready';$reasons=[System.Collections.Generic.List[string]]::new();if($blocked.Count -gt 0){$status='Blocked';foreach($r in $blocked){[void]$reasons.Add($r)}}elseif($needsProfile.Count -gt 0){$status='NeedsProfile';foreach($s in $needsProfile){[void]$reasons.Add("$($s.key) remains unresolved or requires a matching capability profile.")}}elseif($needsValidation.Count -gt 0){$status='NeedsValidation';foreach($s in $needsValidation){[void]$reasons.Add("$($s.key) remains validation-required.")}}else{[void]$reasons.Add('All required build-time and native macOS runtime capabilities are resolved, and the generated config.plist passed the pinned ocvalidate.')}
    Write-DevintoshStepLog $step "Readiness decision: $status." $(if($status -eq 'Ready'){'PASS'}else{'WARN'})

    $step++;Write-DevintoshProgress $step $totalSteps 'Writing transactional readiness report'
    $source=@($loaded|ForEach-Object{[pscustomobject]@{key=$_.key;path=$_.path;required=$_.required;exists=$_.exists;valid=$_.valid;status=Get-Status $_}})
    $report=[ordered]@{schemaVersion=2;generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture);status=$status;applied=$false;policy='conservative-preboot-readiness-gate';sourceReports=$source;capabilityStates=@($states);nativeMacosValidation=[pscustomobject]@{present=[bool]$mac.exists;status=if($mac.exists){Get-Status $mac}else{'NotCollected'};path=$mac.path};validation=[pscustomobject]@{status=$vs;validatorExitCode=$exit;openCoreVersion=$ver;target='build/efi/EFI/OC/config.plist'};reasons=@($reasons);blockingIssues=@($blocked);generatedArtifacts=@('build/opencore/readiness-report.json');intentionallyNotGenerated=@('SMBIOS unique identifiers','GPU spoofing or DeviceProperties','ACPI patches or SSDTs','USB port maps','Audio layout IDs or routing','Network interface configuration','Any hardware-specific mutation')}
    Write-ReportTransactional ([pscustomobject]$report);Write-DevintoshStepLog $step 'Readiness report written transactionally.' 'PASS'

    $step++;Write-DevintoshProgress $step $totalSteps 'Finalizing readiness gate';Complete-DevintoshTransaction;Complete-DevintoshProgress 'Readiness evaluation complete';$EXIT_CODE=$script:EXIT_SUCCESS
}
catch{Write-DevintoshLog 'ERROR' "Readiness gate failed: $($_.Exception.Message)";try{$ok=Invoke-DevintoshRollback;if(-not$ok){$EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE}}catch{$EXIT_CODE=$script:EXIT_ROLLBACK_FAILURE};if($EXIT_CODE-eq$script:EXIT_SUCCESS){$EXIT_CODE=$script:EXIT_GENERAL_FAILURE}}
exit $EXIT_CODE
