#requires -Version 5.1
<#
.SYNOPSIS
    Shared fixed-line indigo-to-blue progress bar.

.DESCRIPTION
    Keeps the active progress line visually isolated from subsequent step/result
    messages. Callers may safely write normal console output immediately after a
    progress update without concatenating it onto the progress bar.

    When main.ps1 launches a child stage, DEVINTOSH_GLOBAL_STEP_OFFSET,
    DEVINTOSH_GLOBAL_STEP_TOTAL, and DEVINTOSH_GLOBAL_STAGE_TOTAL are inherited
    by the child process. The local stage step is then rendered as a position in
    the complete pipeline, so step progress and percentages do not reset when a
    new script starts. Direct execution without these variables retains the
    script-local behavior.
#>

Set-StrictMode -Version Latest

function Get-DevintoshGlobalStepNumber {
    param([Parameter(Mandatory)][int]$Number)

    $offset = 0
    if ($env:DEVINTOSH_GLOBAL_STEP_OFFSET) {
        $parsed = 0
        if ([int]::TryParse($env:DEVINTOSH_GLOBAL_STEP_OFFSET, [ref]$parsed)) {
            $offset = [math]::Max(0, $parsed)
        }
    }

    return $offset + $Number
}

function Get-DevintoshProgressTotal {
    param([Parameter(Mandatory)][int]$LocalTotal)

    if ($env:DEVINTOSH_GLOBAL_STEP_TOTAL) {
        $parsed = 0
        if ([int]::TryParse($env:DEVINTOSH_GLOBAL_STEP_TOTAL, [ref]$parsed) -and $parsed -gt 0) {
            return $parsed
        }
    }

    return $LocalTotal
}

function Get-DevintoshStageTotal {
    param([Parameter(Mandatory)][int]$Fallback)

    if ($env:DEVINTOSH_GLOBAL_STAGE_TOTAL) {
        $parsed = 0
        if ([int]::TryParse($env:DEVINTOSH_GLOBAL_STAGE_TOTAL, [ref]$parsed) -and $parsed -gt 0) {
            return $parsed
        }
    }

    return $Fallback
}

function Write-DevintoshProgress {
    param(
        [Parameter(Mandatory)][int]$Current,
        [Parameter(Mandatory)][int]$Total,
        [Parameter(Mandatory)][string]$Activity
    )

    $globalCurrent = Get-DevintoshGlobalStepNumber -Number $Current
    $globalTotal = Get-DevintoshProgressTotal -LocalTotal $Total
    $percent = if ($globalTotal -le 0) { 100 } else { [math]::Min(100, [math]::Max(0, [math]::Round(($globalCurrent / $globalTotal) * 100))) }
    $width = 32
    $filled = [math]::Floor(($percent / 100) * $width)
    $filledChar = [char]0x2588
    $emptyChar = [char]0x2591
    $start = @(99, 102, 241)
    $end = @(59, 130, 246)
    $bar = [Text.StringBuilder]::new()

    for ($i = 0; $i -lt $width; $i++) {
        if ($i -lt $filled) {
            $ratio = if ($width -eq 1) { 1 } else { $i / ($width - 1) }
            $r = [math]::Round($start[0] + (($end[0] - $start[0]) * $ratio))
            $g = [math]::Round($start[1] + (($end[1] - $start[1]) * $ratio))
            $b = [math]::Round($start[2] + (($end[2] - $start[2]) * $ratio))
            [void]$bar.Append("$($script:Esc)[38;2;${r};${g};${b}m$filledChar$($script:Reset)")
        } else {
            [void]$bar.Append("$($script:Gray)$emptyChar$($script:Reset)")
        }
    }

    $activityText = if ($Activity.Length -gt 34) { $Activity.Substring(0, 34) } else { $Activity }
    $line = "  $($bar.ToString()) $($script:White)$percent%$($script:Reset)  $($script:Gray)$activityText$($script:Reset)"
    Write-Host -NoNewline "`r$($script:Esc)[2K$line"
}

function Complete-DevintoshProgress {
    param([string]$Message = 'Complete')
    Write-Host -NoNewline "`r$($script:Esc)[2K"
    $stageTotal = Get-DevintoshStageTotal -Fallback 100
    Write-DevintoshProgress $stageTotal $stageTotal $Message
    Write-Host ''
}

function Clear-DevintoshProgressLine {
    Write-Host -NoNewline "`r$($script:Esc)[2K"
}
