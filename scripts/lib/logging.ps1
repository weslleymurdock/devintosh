#requires -Version 5.1
<#
.SYNOPSIS
    Shared en-US file and console logging helpers.

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
    9 = Blocking warning. A stage completed its operation but explicitly
        classified a warning as preventing pipeline continuation.
#>

Set-StrictMode -Version Latest

if (-not (Get-Variable -Name DevintoshLogFile -Scope Script -ErrorAction SilentlyContinue)) {
    $script:DevintoshLogFile = $null
}

function Initialize-DevintoshLogging {
    param([string]$Name = 'devintosh')
    if (-not (Test-Path -LiteralPath $script:LogRoot)) {
        New-Item -ItemType Directory -Path $script:LogRoot -Force | Out-Null
    }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::GetCultureInfo('en-US'))
    $script:DevintoshLogFile = Join-Path $script:LogRoot "$Name-$stamp.log"
    "[$(Get-Timestamp)] [INFO] Log started: $Name" | Set-Content -LiteralPath $script:DevintoshLogFile -Encoding UTF8
}

function Write-DevintoshLog {
    param(
        [Parameter(Mandatory)][ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )
    $line = "[$(Get-Timestamp)] [$Level] $Message"
    if ($script:DevintoshLogFile) { Add-Content -LiteralPath $script:DevintoshLogFile -Value $line -Encoding UTF8 }
}

function Write-DevintoshStepLog {
    param(
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('RUN','PASS','WARN','FAIL')][string]$Status = 'RUN'
    )
    $globalNumber = if (Get-Command Get-DevintoshGlobalStepNumber -ErrorAction SilentlyContinue) {
        Get-DevintoshGlobalStepNumber -Number $Number
    } else {
        $Number
    }
    Write-DevintoshStep -Number $Number -Message $Message -Status $Status
    $level = switch ($Status) { 'WARN' { 'WARN' } 'FAIL' { 'ERROR' } default { 'INFO' } }
    Write-DevintoshLog -Level $level -Message ("[STEP {0:d2}] {1}: {2}" -f $globalNumber, $Status, $Message)
}
