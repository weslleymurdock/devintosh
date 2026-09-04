#requires -Version 5.1
<#
.SYNOPSIS
    Shared fixed-line indigo-to-blue progress bar.

.DESCRIPTION
    Keeps the active progress line visually isolated from subsequent step/result
    messages. Callers may safely write normal console output immediately after a
    progress update without concatenating it onto the progress bar.
#>

Set-StrictMode -Version Latest

function Write-DevintoshProgress {
    param(
        [Parameter(Mandatory)][int]$Current,
        [Parameter(Mandatory)][int]$Total,
        [Parameter(Mandatory)][string]$Activity
    )

    $percent = if ($Total -le 0) { 100 } else { [math]::Min(100, [math]::Max(0, [math]::Round(($Current / $Total) * 100))) }
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
    # Clear the complete terminal row before redrawing it. This prevents stale
    # characters from a longer previous activity from remaining visible.
    Write-Host -NoNewline "`r$($script:Esc)[2K$line"
}

function Complete-DevintoshProgress {
    param([string]$Message = 'Complete')
    Write-Host -NoNewline "`r$($script:Esc)[2K"
    Write-DevintoshProgress 100 100 $Message
    Write-Host ''
}

function Clear-DevintoshProgressLine {
    Write-Host -NoNewline "`r$($script:Esc)[2K"
}
