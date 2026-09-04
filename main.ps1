#requires -Version 5.1
<#
.SYNOPSIS
    Runs the complete Devintosh build pipeline from a clean clone.
.DESCRIPTION
    Executes every non-destructive preparation and OpenCore generation stage in
    isolated Windows PowerShell 5.1 child processes. A non-zero exit code stops
    the pipeline immediately. The selected macOS target is propagated through
    DEVINTOSH_MACOS_VERSION so version-sensitive stages consume one profile.

    The final prepare-boot-disk.ps1 stage is intentionally invoked only after the
    non-destructive boot-artifact gate has succeeded. No destructive confirmation
    is requested until the generated EFI and verified Recovery payload are known
    to exist.
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$StopOnWarning,
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.-]*$')]
    [string]$MacOSVersion = 'sequoia'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = $PSScriptRoot
$scriptRoot = Join-Path $repoRoot 'scripts'
$logRoot = Join-Path $repoRoot 'logs'
$Esc = [char]27
$Reset = "$Esc[0m"
$Green = "$Esc[38;2;74;222;128m"
$Yellow = "$Esc[38;2;250;204;21m"
$Red = "$Esc[38;2;248;113;113m"
$Gray = "$Esc[38;2;148;163;184m"
$Magenta = "$Esc[38;2;232;121;249m"
$MainTag = "$Magenta[MAIN]$Reset"
$EXIT_BLOCKING_WARNING = 9

$pipeline = @(
    'validate.ps1'
    'prepare.ps1'
    'download-recovery.ps1'
    'build-opencore.ps1'
    'configure-opencore-hardware.ps1'
    'configure-opencore.ps1'
    'acquire-opencore-drivers.ps1'
    'resolve-gpu.ps1'
    'apply-opencore-profiles.ps1'
    'resolve-smbios.ps1'
    'bootstrap-smbios.ps1'
    'configure-first-boot.ps1'
    'resolve-acpi.ps1'
    'resolve-usb.ps1'
    'resolve-network.ps1'
    'resolve-audio.ps1'
    'resolve-kexts.ps1'
    'acquire-kext-assets.ps1'
    'compose-opencore-kexts.ps1'
    'validate-opencore.ps1'
    'readiness.ps1'
    'verify-boot-artifacts.ps1'
)

function Get-StageStepCount {
    param([Parameter(Mandatory = $true)][string]$ScriptPath)
    $content = Get-Content -LiteralPath $ScriptPath -Raw -Encoding UTF8
    $matches = [regex]::Matches($content, '(?i)\$totalSteps\s*=\s*(\d+)')
    if ($matches.Count -eq 0) { throw "Pipeline stage does not declare a static total step count: $([System.IO.Path]::GetFileName($ScriptPath))" }
    $counts = @($matches | ForEach-Object { [int]$_.Groups[1].Value })
    if ($counts.Count -ne 1 -or $counts[0] -le 0) { throw "Pipeline stage must declare exactly one positive `$totalSteps value: $([System.IO.Path]::GetFileName($ScriptPath))" }
    return $counts[0]
}

function Get-PipelineStepPlan {
    param([Parameter(Mandatory = $true)][string[]]$Scripts)
    $plan = [System.Collections.Generic.List[object]]::new();$offset=0
    foreach($scriptName in $Scripts){$path=Join-Path $scriptRoot $scriptName;if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Required pipeline stage is missing: $scriptName"};$count=Get-StageStepCount $path;[void]$plan.Add([pscustomobject]@{ScriptName=$scriptName;StepCount=$count;StepOffset=$offset});$offset+=$count}
    return [pscustomobject]@{Stages=@($plan.ToArray());TotalSteps=$offset}
}

function Get-StageLogDiagnostics {
    param([Parameter(Mandatory)][string]$ScriptName,[Parameter(Mandatory)][datetime]$StartedAt)
    if(-not(Test-Path -LiteralPath $logRoot -PathType Container)){return @()}
    $baseName=[System.IO.Path]::GetFileNameWithoutExtension($ScriptName)
    $files=@(Get-ChildItem -LiteralPath $logRoot -Filter "$baseName-*.log" -File -ErrorAction SilentlyContinue|Where-Object{$_.LastWriteTime-ge$StartedAt.AddSeconds(-2)}|Sort-Object LastWriteTime -Descending)
    $diagnostics=[System.Collections.Generic.List[string]]::new();foreach($file in $files){foreach($line in @(Get-Content -LiteralPath $file.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)){if($line-match'\[(WARN|ERROR)\]'){[void]$diagnostics.Add($line)}}};return @($diagnostics.ToArray())
}

function Write-StageDiagnostics {
    param([Parameter(Mandatory)][string]$ScriptName,[string[]]$Diagnostics=@())
    if($null-eq$Diagnostics-or$Diagnostics.Count-eq0){return}
    Write-Host '';Write-Host "$MainTag Diagnostics from ${ScriptName}:"
    foreach($line in $Diagnostics){if($line-match'\[ERROR\]'){Write-Host "$Red$line$Reset"}elseif($line-match'\[WARN\]'){Write-Host "$Yellow$line$Reset"}else{Write-Host $line}}
}

function Invoke-PipelineStep {
    param([Parameter(Mandatory)][string]$ScriptName,[Parameter(Mandatory)][int]$GlobalStepOffset,[Parameter(Mandatory)][int]$GlobalStepTotal,[Parameter(Mandatory)][int]$StageStepTotal,[switch]$PassForce,[switch]$FailOnWarning)
    $path=Join-Path $scriptRoot $ScriptName;if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Pipeline script not found: $path"}
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$path);if($PassForce){$arguments+='-Force'}
    Write-Host '';Write-Host ("{0} Starting {1} (global steps {2}-{3} of {4})"-f$MainTag,$ScriptName,($GlobalStepOffset+1),($GlobalStepOffset+$StageStepTotal),$GlobalStepTotal)
    $previousOffset=$env:DEVINTOSH_GLOBAL_STEP_OFFSET;$previousTotal=$env:DEVINTOSH_GLOBAL_STEP_TOTAL;$previousStageTotal=$env:DEVINTOSH_GLOBAL_STAGE_TOTAL
    try{$env:DEVINTOSH_GLOBAL_STEP_OFFSET=[string]$GlobalStepOffset;$env:DEVINTOSH_GLOBAL_STEP_TOTAL=[string]$GlobalStepTotal;$env:DEVINTOSH_GLOBAL_STAGE_TOTAL=[string]$StageStepTotal;$stageStartedAt=Get-Date;& powershell.exe @arguments;$code=[int]$LASTEXITCODE}
    finally{if($null-eq$previousOffset){Remove-Item Env:DEVINTOSH_GLOBAL_STEP_OFFSET -ErrorAction SilentlyContinue}else{$env:DEVINTOSH_GLOBAL_STEP_OFFSET=$previousOffset};if($null-eq$previousTotal){Remove-Item Env:DEVINTOSH_GLOBAL_STEP_TOTAL -ErrorAction SilentlyContinue}else{$env:DEVINTOSH_GLOBAL_STEP_TOTAL=$previousTotal};if($null-eq$previousStageTotal){Remove-Item Env:DEVINTOSH_GLOBAL_STAGE_TOTAL -ErrorAction SilentlyContinue}else{$env:DEVINTOSH_GLOBAL_STAGE_TOTAL=$previousStageTotal}}
    $diagnostics=@(Get-StageLogDiagnostics -ScriptName $ScriptName -StartedAt $stageStartedAt);$warnings=@($diagnostics|Where-Object{$_-match'\[WARN\]'})
    if($code-ne0){Write-StageDiagnostics -ScriptName $ScriptName -Diagnostics $diagnostics;if($FailOnWarning-and$code-eq$EXIT_BLOCKING_WARNING){Write-Host "$Yellow$MainTag STOP: $ScriptName completed with a blocking warning (exit code $EXIT_BLOCKING_WARNING); -StopOnWarning is active. No subsequent pipeline stage will run.$Reset"}else{Write-Host ("{0} STOP: {1} failed with exit code {2}. No subsequent pipeline stage will run."-f$MainTag,$ScriptName,$code)};exit $code}
    if($warnings.Count-gt0){Write-StageDiagnostics -ScriptName $ScriptName -Diagnostics $warnings;Write-Host "$Gray$MainTag $ScriptName returned exit code 0; warning(s) are advisory and the pipeline will continue.$Reset"}
    Write-Host ("{0} Completed {1} successfully."-f$MainTag,$ScriptName)
}

try {
    if(-not(Test-Path -LiteralPath (Join-Path $repoRoot '.git') -PathType Container)){throw 'main.ps1 must be executed from the root of a clean cloned Devintosh repository.'}
    $normalizedVersion=$MacOSVersion.Trim().ToLowerInvariant();$versionPath=Join-Path $repoRoot ("config\versions\{0}.json"-f$normalizedVersion)
    if(-not(Test-Path -LiteralPath $versionPath -PathType Leaf)){throw "macOS target profile '$normalizedVersion' was not found: $versionPath"}
    $versionProfile=Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8|ConvertFrom-Json
    if([string]$versionProfile.id-ne$normalizedVersion){throw "macOS target profile id mismatch: expected '$normalizedVersion', found '$($versionProfile.id)'."}
    $env:DEVINTOSH_MACOS_VERSION=$normalizedVersion

    $buildRoot=Join-Path $repoRoot 'build'
    if(Test-Path -LiteralPath $buildRoot -PathType Container){$buildEntries=@(Get-ChildItem -LiteralPath $buildRoot -Force -ErrorAction SilentlyContinue);if($buildEntries.Count-gt0){throw 'The repository is not in a clean build state. Remove the build directory and rerun main.ps1 from a clean clone.'}}

    $stepPlan=Get-PipelineStepPlan -Scripts $pipeline
    $finalScript=Join-Path $scriptRoot 'prepare-boot-disk.ps1';if(-not(Test-Path -LiteralPath $finalScript -PathType Leaf)){throw 'Required final pipeline stage is missing: prepare-boot-disk.ps1'}
    $finalStepCount=Get-StageStepCount $finalScript;$globalStepTotal=$stepPlan.TotalSteps+$finalStepCount

    Write-Host '';Write-Host '============================================================';Write-Host 'DEVINTOSH - COMPLETE CLEAN-CLONE PIPELINE';Write-Host '============================================================';Write-Host 'Every stage runs in an isolated PowerShell 5.1 process.';Write-Host 'The pipeline stops immediately on the first non-zero exit code.';Write-Host ("macOS target        : {0} (major {1})"-f$versionProfile.name,$versionProfile.macOSMajorVersion);Write-Host ("OpenCore target     : {0}"-f$versionProfile.opencore.version);Write-Host ("Global step count  : {0}"-f$globalStepTotal)
    if($StopOnWarning){Write-Host "$Green Warning gate       : ACTIVE (-StopOnWarning; exit code 9)$Reset"}else{Write-Host "$Gray Warning gate       : OFF (use -StopOnWarning for regression testing)$Reset"}
    Write-Host 'Exit code 0 permits continuation, including advisory WARN entries.';Write-Host 'No stage after a failure or blocking warning is executed.';Write-Host 'Boot-artifact verification is completed before destructive disk selection.';Write-Host 'Disk preparation is intentionally the final interactive stage.';Write-Host '============================================================'
    foreach($stage in $stepPlan.Stages){Invoke-PipelineStep -ScriptName $stage.ScriptName -GlobalStepOffset $stage.StepOffset -GlobalStepTotal $globalStepTotal -StageStepTotal $stage.StepCount -PassForce:$Force -FailOnWarning:$StopOnWarning}
    Write-Host '';Write-Host "$MainTag Reaching final disk setup.";Write-Host "$MainTag All non-destructive boot artifact checks have passed.";Write-Host "$MainTag The available physical disks will now be displayed for interactive selection.";Write-Host ''
    Invoke-PipelineStep -ScriptName 'prepare-boot-disk.ps1' -GlobalStepOffset $stepPlan.TotalSteps -GlobalStepTotal $globalStepTotal -StageStepTotal $finalStepCount -FailOnWarning:$StopOnWarning
    Write-Host '';Write-Host "$MainTag COMPLETE: all Devintosh pipeline stages succeeded.";exit 0
}
catch{Write-Host ("{0} STOP: {1}"-f$MainTag,$_.Exception.Message);exit 1}
