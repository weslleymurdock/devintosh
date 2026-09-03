#requires -Version 5.1
<#
.SYNOPSIS
    Shared transaction and automatic rollback helpers.

.DESCRIPTION
    Tracks reversible actions in memory and executes them in reverse order when
    a preparation/build transaction fails. Rollback is automatic and is never
    exposed as a required user operation.

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

$script:RollbackActions = [System.Collections.Generic.List[object]]::new()

function Start-DevintoshTransaction {
    $script:RollbackActions.Clear()
    Write-DevintoshLog -Level 'DEBUG' -Message 'Automatic rollback transaction started.'
}

function Add-DevintoshRollbackAction {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    $script:RollbackActions.Add([pscustomobject]@{ Name = $Name; Action = $Action })
    Write-DevintoshLog -Level 'DEBUG' -Message "Rollback registered: $Name"
}

function Invoke-DevintoshRollback {
    $failureCount = 0
    for ($i = $script:RollbackActions.Count - 1; $i -ge 0; $i--) {
        $item = $script:RollbackActions[$i]
        Write-DevintoshStepLog -Number 99 -Message "Rollback: $($item.Name)" -Status 'RUN'
        try {
            & $item.Action
            Write-DevintoshStepLog -Number 99 -Message "Rollback: $($item.Name) completed." -Status 'PASS'
        } catch {
            $failureCount++
            Write-DevintoshStepLog -Number 99 -Message "Rollback: $($item.Name) failed: $($_.Exception.Message)" -Status 'FAIL'
        }
    }
    $script:RollbackActions.Clear()
    return ($failureCount -eq 0)
}

function Complete-DevintoshTransaction {
    $script:RollbackActions.Clear()
    Write-DevintoshLog -Level 'DEBUG' -Message 'Transaction completed; rollback stack cleared.'
}
