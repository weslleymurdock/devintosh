#requires -Version 5.1
<#
.SYNOPSIS
    Reusable interactive selection menu for destructive Devintosh stages.
#>
Set-StrictMode -Version Latest

function Select-DevintoshMenuItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][array]$Items,
        [Parameter(Mandatory)][scriptblock]$LabelScript,
        [string]$Title = 'Select an item',
        [string]$Prompt = 'Enter the item number',
        [switch]$AllowCancel
    )

    if ($Items.Count -eq 0) { throw 'No selectable items were provided.' }

    while ($true) {
        Write-Host ''
        Write-Host $Title -ForegroundColor Cyan
        Write-Host ('=' * [Math]::Min(78, [Math]::Max(20, $Title.Length))) -ForegroundColor DarkCyan

        for ($i = 0; $i -lt $Items.Count; $i++) {
            $label = & $LabelScript $Items[$i]
            Write-Host (' [{0}] {1}' -f ($i + 1), $label)
        }
        if ($AllowCancel) { Write-Host ' [Q] Cancel' -ForegroundColor Yellow }

        $answer = Read-Host $Prompt
        if ($AllowCancel -and $answer -match '^(?i:q|quit|cancel)$') { return $null }

        [int]$index = 0
        if ([int]::TryParse($answer, [ref]$index) -and $index -ge 1 -and $index -le $Items.Count) {
            return $Items[$index - 1]
        }
        Write-Host 'Invalid selection. Choose one of the displayed numbers.' -ForegroundColor Yellow
    }
}

function Confirm-DevintoshDestructiveSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceDescription,
        [Parameter(Mandatory)][string]$ConfirmationToken,
        [string[]]$WarningLines = @()
    )

    Write-Host ''
    Write-Host 'DESTRUCTIVE OPERATION' -ForegroundColor Red
    Write-Host 'This operation cannot be rolled back after the destructive storage command starts.' -ForegroundColor Red
    Write-Host "Target: $ResourceDescription" -ForegroundColor Yellow
    foreach ($line in $WarningLines) { Write-Host "WARNING: $line" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host "Type '$ConfirmationToken' exactly to continue, or press Enter to cancel." -ForegroundColor Cyan
    $answer = Read-Host 'Confirmation'
    return $answer -ceq $ConfirmationToken
}
