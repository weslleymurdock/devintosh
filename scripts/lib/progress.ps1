#requires -Version 5.1
<#
.SYNOPSIS
    Shared fixed-line indigo-to-blue progress bar.

.EXIT CODES
    0 = Success (library does not terminate the process).
    1 = General failure.
    2 = Validation failure.
    3 = Insufficient privileges.
    4 = Target device or resource not found.
    5 = Backup or rollback failure.
    6 = External dependency failure.
    7 = Asset integrity failure.
    8 = Unsupported hardware or configuration.
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
    Write-Host -NoNewline "`r$line"
}

function Complete-DevintoshProgress {
    param([string]$Message = 'Complete')
    Write-DevintoshProgress 100 100 $Message
    Write-Host ''
}
