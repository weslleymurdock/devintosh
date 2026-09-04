#requires -Version 5.1
<#
.SYNOPSIS
    Runs the complete Devintosh build pipeline from a clean clone.
.DESCRIPTION
    Executes every non-destructive preparation and OpenCore generation stage in
    an isolated Windows PowerShell 5.1 child process. A non-zero exit code stops
    the pipeline immediately; later stages are never run.

    -StopOnWarning enables the explicit blocking-warning contract. A stage must
    return the dedicated blocking-warning exit code (9) to stop the pipeline as
    a warning. A plain [WARN] log entry is advisory and does not stop a stage;
    this allows deferred conditions to be resolved by later pipeline stages.

    Step progress is global across the complete pipeline. main.ps1 reads each
    stage's declared $totalSteps, calculates the aggregate number of steps, and
    passes the current global offset/total to each isolated child process.
    Shared progress and logging helpers use those values so step numbers and
    percentages do not reset when a new script starts.

    The final prepare-boot-disk.ps1 stage is intentionally invoked without a
    target disk number and without -Force. It therefore presents the available
    physical disks for interactive selection and retains all destructive safety
    confirmations. No later pipeline stage exists after disk preparation.

.PARAMETER Force
    Passes -Force to non-destructive pipeline stages. It never bypasses the
    active Windows disk protection or the final destructive disk confirmation.

.PARAMETER StopOnWarning
    Enables strict handling of warnings that are explicitly classified by the
    child stage as blocking. A blocking warning is represented by exit code 9.
    Ordinary [WARN] log entries from a successful stage remain non-blocking.
    This switch may be combined with -Force.
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$StopOnWarning
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
)

function Get-StageStepCount {
    param([Parameter(Mandatory = $true)][string]$ScriptPath)

    $content = Get-Content -LiteralPath $ScriptPath -Raw -Encoding UTF8
    $matches = [regex]::Matches($content, '(?im)^\s*\$totalSteps\s*=\s*(\d+)\s*$')
    if ($matches.Count -eq 0) {
        throw "Pipeline stage does not declare a static total step count: $([System.IO.Path]::GetFileName($ScriptPath))"
    }

    $counts = @($matches | ForEach-Object { [int]$_.Groups[1].Value })
    if ($counts.Count -ne 1 -or $counts[0] -le 0) {
        throw "Pipeline stage must declare exactly one positive `$totalSteps value: $([System.IO.Path]::GetFileName($ScriptPath))"
    }

    return $counts[0]
}

function Get-PipelineStepPlan {
    param([Parameter(Mandatory = $true)][string[]]$Scripts)

    $plan = [System.Collections.Generic.List[object]]::new()
    $offset = 0

    foreach ($scriptName in $Scripts) {
        $path = Join-Path $scriptRoot $scriptName
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required pipeline stage is missing: $scriptName"
        }

        $count = Get-StageStepCount -ScriptPath $path
        [void]$plan.Add([pscustomobject]@{
            ScriptName = $scriptName
            StepCount = $count
            StepOffset = $offset
        })
        $offset += $count
    }

    return [pscustomobject]@{
        Stages = @($plan.ToArray())
        TotalSteps = $offset
    }
}

function Get-StageLogDiagnostics {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptName,
        [Parameter(Mandatory = $true)]
        [datetime]$StartedAt
    )

    if (-not (Test-Path -LiteralPath $logRoot -PathType Container)) {
        return @()
    }

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($ScriptName)
    $files = @(Get-ChildItem -LiteralPath $logRoot -Filter "$baseName-*.log" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $StartedAt.AddSeconds(-2) } |
        Sort-Object LastWriteTime -Descending)

    $diagnostics = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $files) {
        foreach ($line in @(Get-Content -LiteralPath $file.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            if ($line -match '\[(WARN|ERROR)\]') {
                [void]$diagnostics.Add($line)
            }
        }
    }

    return @($diagnostics.ToArray())
}

function Write-StageDiagnostics {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptName,
        [string[]]$Diagnostics = @()
    )

    if ($null -eq $Diagnostics -or $Diagnostics.Count -eq 0) {
        return
    }

    Write-Host ''
    Write-Host "$Gray[MAIN] Diagnostics from ${ScriptName}:$Reset"
    foreach ($line in $Diagnostics) {
        if ($line -match '\[ERROR\]') {
            Write-Host "$Red$line$Reset"
        } elseif ($line -match '\[WARN\]') {
            Write-Host "$Yellow$line$Reset"
        } else {
            Write-Host $line
        }
    }
}

function Invoke-PipelineStep {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptName,
        [Parameter(Mandatory = $true)]
        [int]$GlobalStepOffset,
        [Parameter(Mandatory = $true)]
        [int]$GlobalStepTotal,
        [Parameter(Mandatory = $true)]
        [int]$StageStepTotal,
        [switch]$PassForce,
        [switch]$FailOnWarning
    )

    $path = Join-Path $scriptRoot $ScriptName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Pipeline script not found: $path"
    }

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $path)
    if ($PassForce) {
        $arguments += '-Force'
    }

    Write-Host ''
    Write-Host ("[MAIN] Starting {0} (global steps {1}-{2} of {3})" -f $ScriptName, ($GlobalStepOffset + 1), ($GlobalStepOffset + $StageStepTotal), $GlobalStepTotal)

    $previousOffset = $env:DEVINTOSH_GLOBAL_STEP_OFFSET
    $previousTotal = $env:DEVINTOSH_GLOBAL_STEP_TOTAL
    $previousStageTotal = $env:DEVINTOSH_GLOBAL_STAGE_TOTAL
    try {
        $env:DEVINTOSH_GLOBAL_STEP_OFFSET = [string]$GlobalStepOffset
        $env:DEVINTOSH_GLOBAL_STEP_TOTAL = [string]$GlobalStepTotal
        $env:DEVINTOSH_GLOBAL_STAGE_TOTAL = [string]$StageStepTotal

        $stageStartedAt = Get-Date
        & powershell.exe @arguments
        $code = [int]$LASTEXITCODE
    }
    finally {
        if ($null -eq $previousOffset) { Remove-Item Env:DEVINTOSH_GLOBAL_STEP_OFFSET -ErrorAction SilentlyContinue } else { $env:DEVINTOSH_GLOBAL_STEP_OFFSET = $previousOffset }
        if ($null -eq $previousTotal) { Remove-Item Env:DEVINTOSH_GLOBAL_STEP_TOTAL -ErrorAction SilentlyContinue } else { $env:DEVINTOSH_GLOBAL_STEP_TOTAL = $previousTotal }
        if ($null -eq $previousStageTotal) { Remove-Item Env:DEVINTOSH_GLOBAL_STAGE_TOTAL -ErrorAction SilentlyContinue } else { $env:DEVINTOSH_GLOBAL_STAGE_TOTAL = $previousStageTotal }
    }

    $diagnostics = @(Get-StageLogDiagnostics -ScriptName $ScriptName -StartedAt $stageStartedAt)
    $warnings = @($diagnostics | Where-Object { $_ -match '\[WARN\]' })

    if ($code -ne 0) {
        Write-StageDiagnostics -ScriptName $ScriptName -Diagnostics $diagnostics

        if ($FailOnWarning -and $code -eq $EXIT_BLOCKING_WARNING) {
            Write-Host "$Yellow[MAIN] STOP: $ScriptName completed with a blocking warning (exit code $EXIT_BLOCKING_WARNING); -StopOnWarning is active. No subsequent pipeline stage will run.$Reset"
        } else {
            Write-Host ("[MAIN] STOP: {0} failed with exit code {1}. No subsequent pipeline stage will run." -f $ScriptName, $code)
        }

        exit $code
    }

    if ($warnings.Count -gt 0) {
        Write-StageDiagnostics -ScriptName $ScriptName -Diagnostics $warnings
        Write-Host "$Gray[MAIN] $ScriptName returned exit code 0; warning(s) are advisory and the pipeline will continue.$Reset"
    }

    Write-Host ("[MAIN] Completed {0} successfully." -f $ScriptName)
}

try {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot '.git') -PathType Container)) {
        throw 'main.ps1 must be executed from the root of a clean cloned Devintosh repository.'
    }

    $buildRoot = Join-Path $repoRoot 'build'
    if (Test-Path -LiteralPath $buildRoot -PathType Container) {
        $buildEntries = @(Get-ChildItem -LiteralPath $buildRoot -Force -ErrorAction SilentlyContinue)
        if ($buildEntries.Count -gt 0) {
            throw 'The repository is not in a clean build state. Remove the build directory and rerun main.ps1 from a clean clone.'
        }
    }

    $stepPlan = Get-PipelineStepPlan -Scripts $pipeline
    $finalScript = Join-Path $scriptRoot 'prepare-boot-disk.ps1'
    if (-not (Test-Path -LiteralPath $finalScript -PathType Leaf)) {
        throw 'Required final pipeline stage is missing: prepare-boot-disk.ps1'
    }
    $finalStepCount = Get-StageStepCount -ScriptPath $finalScript
    $globalStepTotal = $stepPlan.TotalSteps + $finalStepCount

    Write-Host ''
    Write-Host '============================================================'
    Write-Host 'DEVINTOSH - COMPLETE CLEAN-CLONE PIPELINE'
    Write-Host '============================================================'
    Write-Host 'Every stage runs in an isolated PowerShell 5.1 process.'
    Write-Host 'The pipeline stops immediately on the first non-zero exit code.'
    Write-Host ("Global step count  : {0}" -f $globalStepTotal)
    if ($StopOnWarning) {
        Write-Host "$Green Warning gate       : ACTIVE (-StopOnWarning; exit code 9)$Reset"
    } else {
        Write-Host "$Gray Warning gate       : OFF (use -StopOnWarning for regression testing)$Reset"
    }
    Write-Host 'Exit code 0 permits continuation, including advisory WARN entries.'
    Write-Host 'No stage after a failure or blocking warning is executed.'
    Write-Host 'Disk preparation is intentionally the final interactive stage.'
    Write-Host '============================================================'

    foreach ($stage in $stepPlan.Stages) {
        Invoke-PipelineStep -ScriptName $stage.ScriptName -GlobalStepOffset $stage.StepOffset -GlobalStepTotal $globalStepTotal -StageStepTotal $stage.StepCount -PassForce:$Force -FailOnWarning:$StopOnWarning
    }

    Write-Host ''
    Write-Host '[MAIN] Reaching final disk setup.'
    Write-Host '[MAIN] The available physical disks will now be displayed for interactive selection.'
    Write-Host '[MAIN] No target disk is supplied automatically.'
    Write-Host ''

    Invoke-PipelineStep -ScriptName 'prepare-boot-disk.ps1' -GlobalStepOffset $stepPlan.TotalSteps -GlobalStepTotal $globalStepTotal -StageStepTotal $finalStepCount -FailOnWarning:$StopOnWarning

    Write-Host ''
    Write-Host '[MAIN] COMPLETE: all Devintosh pipeline stages succeeded.'
    exit 0
}
catch {
    Write-Host ("[MAIN] STOP: {0}" -f $_.Exception.Message)
    exit 1
}
