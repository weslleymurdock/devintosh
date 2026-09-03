#requires -Version 5.1
<#
.SYNOPSIS
    Shared ANSI console helpers for Devintosh.

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

$script:Esc = [char]27
$script:Reset = "$($script:Esc)[0m"
$script:Bold = "$($script:Esc)[1m"
$script:Dim = "$($script:Esc)[2m"
$script:Indigo = "$($script:Esc)[38;2;99;102;241m"
$script:Blue = "$($script:Esc)[38;2;59;130;246m"
$script:Cyan = "$($script:Esc)[38;2;34;211;238m"
$script:Green = "$($script:Esc)[38;2;74;222;128m"
$script:Yellow = "$($script:Esc)[38;2;250;204;21m"
$script:Red = "$($script:Esc)[38;2;248;113;113m"
$script:White = "$($script:Esc)[38;2;241;245;249m"
$script:Gray = "$($script:Esc)[38;2;148;163;184m"

function Write-DevintoshTitle {
    param([Parameter(Mandatory)][string]$Title, [string]$Subtitle = '')
    Clear-Host
    Write-Host ''
    Write-Host "  $($script:Indigo)$($script:Bold)DEVINTOSH$($script:Reset) $($script:Gray)/ $Title$($script:Reset)"
    if ($Subtitle) { Write-Host "  $($script:Dim)$Subtitle$($script:Reset)" }
    Write-Host ''
}

function Write-DevintoshSection {
    param([Parameter(Mandatory)][string]$Title)
    $line = [string]([char]0x2500) * 72
    Write-Host ''
    Write-Host "  $($script:Blue)$($script:Bold)$Title$($script:Reset)"
    Write-Host "  $($script:Gray)$line$($script:Reset)"
}

function Write-DevintoshResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('PASS','WARN','FAIL','INFO')][string]$Status,
        [Parameter(Mandatory)][string]$Detail
    )
    $label = switch ($Status) {
        'PASS' { "$($script:Green)PASS$($script:Reset)" }
        'WARN' { "$($script:Yellow)WARN$($script:Reset)" }
        'FAIL' { "$($script:Red)FAIL$($script:Reset)" }
        default { "$($script:Cyan)INFO$($script:Reset)" }
    }
    Write-Host ("  [{0}] {1,-24} {2}" -f $label, $Name, $Detail)
}

function Write-DevintoshStep {
    param(
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('RUN','PASS','WARN','FAIL')][string]$Status = 'RUN'
    )
    $label = ('STEP {0:d2}' -f $Number)
    $color = switch ($Status) {
        'PASS' { $script:Green }
        'WARN' { $script:Yellow }
        'FAIL' { $script:Red }
        default { $script:Blue }
    }
    Write-Host "[$($color)$label$($script:Reset)] $Message"
}
