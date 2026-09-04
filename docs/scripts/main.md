# `main.ps1`

Orchestrates the complete Windows-side Devintosh preparation pipeline from a clean clone.

## Usage

Normal execution:

```powershell
.\main.ps1
```

Strict regression execution:

```powershell
.\main.ps1 -Force -StopOnWarning
```

## Parameters

### `-Force`

Passed to non-destructive pipeline stages that expose `-Force`. It does not bypass Windows system-disk protection and is never passed to the final destructive `prepare-boot-disk.ps1` stage.

### `-StopOnWarning`

Enables the strict warning gate. After each child stage exits successfully, `main.ps1` reads that stage's log and collects `[WARN]` entries. If any exist, the pipeline stops before the next stage and returns exit code `2`.

The switch is independent from `-Force`; both can and should be used together during clean-environment regression tests.

Without `-StopOnWarning`, warnings are surfaced by `main.ps1` but do not change the historical success/fail behavior of the child stage.

## Diagnostics

Each stage runs in a separate Windows PowerShell 5.1 process. A non-zero exit code is a hard pipeline stop. When a stage fails, `main.ps1` prints the corresponding `WARN` and `ERROR` entries from its log, including details that may not have been visible because the stage progress bar uses an in-place terminal row.

The shared console/progress libraries clear that active row before normal output, so progress updates cannot visually concatenate with `STEP`, `WARN`, or `FAIL` messages.

## Regression protocol

The intended clean-environment regression loop is:

1. Delete the target installation SSD state.
2. Remove the local Devintosh clone.
3. Clone the repository again.
4. Run `main.ps1 -Force -StopOnWarning` as Administrator.
5. Treat the first warning or non-zero exit code as the current regression boundary.
6. Correct the stage without weakening a validation gate or bypassing rollback.
7. Repeat from a clean environment.
8. Continue to boot/EFI/Clover investigation only after the pipeline reaches the final `prepare-boot-disk.ps1` target-disk prompt with no invalid state reported by prior stages.

The final disk stage remains interactive and destructive. It must continue to require explicit target-disk selection and confirmation.
