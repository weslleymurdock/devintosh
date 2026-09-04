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

Enables the strict blocking-warning gate. It does **not** treat every `[WARN]` log entry as a pipeline failure.

Each child script has an exit-code contract. `main.ps1` captures `$LASTEXITCODE` immediately after the isolated PowerShell 5.1 child process finishes and uses that value as the authoritative continuation decision:

| Exit code | Meaning for `main.ps1` |
|---:|---|
| `0` | Stage succeeded and permits continuation. Any `[WARN]` entries are advisory/deferred and are displayed but do not stop the pipeline. |
| `1`-`8` | Stage failed or could not establish the required state. Pipeline stops immediately and the original exit code is preserved. |
| `9` | Stage explicitly classified a warning as **blocking**. With `-StopOnWarning`, the pipeline stops and the blocking warning is reported as such. |

Exit code `9` is the dedicated `EXIT_BLOCKING_WARNING` value defined by `scripts/lib/common.ps1`. A stage must explicitly return this value when it has completed its operation but has determined that a warning prevents the next stage from safely continuing.

A plain `[WARN]` entry is therefore not sufficient to stop the pipeline. This distinction is intentional: some warnings describe hardware limitations, deferred configuration, firmware state, or incomplete information that a later pipeline stage is responsible for resolving.

The switch is independent from `-Force`; both can and should be used together during clean-environment regression tests.

## Global pipeline step statistics

`main.ps1` treats step numbering as a property of the complete pipeline rather than of an individual script.

Before execution, it reads every pipeline script, including the final `prepare-boot-disk.ps1`, and extracts its single declared `$totalSteps` value. These values are summed into the global pipeline step count. Each stage receives its global step offset, the aggregate total, and its own step count through the child process environment.

The shared console and logging helpers apply the offset to each local step number. Consequently, a stage does not restart at `STEP 01` and its progress percentage does not restart at `0%`. The progress bar represents the position of the current step within the complete pipeline.

For example, if the preceding stages account for 19 steps and the next stage declares 5 steps, its local `STEP 01` is rendered as global `STEP 20`, and its final step is global `STEP 24`.

The scripts remain independently executable. When the global environment values are absent, their original local step/progress behavior is retained.

## Current warning classification

The `prepare.ps1` warnings observed on the RX 550 Lexa test system are currently advisory because `prepare.ps1` completes with exit code `0`:

| Step | Warning | Classification | Reason |
|---:|---|---|---|
| `03` | RX 550 Lexa / device `699F`; supported Polaris identity spoofing may be required. | Advisory / deferred | GPU-specific spoofing is intentionally resolved during the OpenCore hardware/profile stages. It is not the responsibility of the initial hardware preparation stage to finalize the spoof. |
| `04` | No target disk selected. | Advisory / deferred | The preparation stage is explicitly non-destructive. Target-disk selection belongs to the final `prepare-boot-disk.ps1` stage. |
| `05` | Secure Boot is disabled. | Advisory / recorded state | Preparation records firmware state and does not modify UEFI settings. Secure Boot policy is part of the later boot/firmware validation rather than this non-destructive preparation stage. |

These warnings must remain visible in diagnostics. They are not silently suppressed; they simply do not override a successful stage exit code.

If a later stage determines that one of these conditions is actually incompatible with its required operation, that stage must express the blocking condition through its own documented non-zero exit code. A warning must never be downgraded merely to make the pipeline continue.

## Pipeline decision flow

For every stage, `main.ps1` performs the following sequence:

1. Start the stage in a separate Windows PowerShell 5.1 process with its global step offset and aggregate step count.
2. Capture `$LASTEXITCODE` immediately after the child process exits.
3. Read the stage log for `WARN`/`ERROR` diagnostics so the result remains visible even when progress output was previously rendered in-place.
4. If the exit code is non-zero, stop immediately and preserve that exit code.
5. If the exit code is `0`, display any advisory warnings and continue to the next stage.
6. When `-StopOnWarning` is active, exit code `9` is explicitly reported as a blocking warning rather than a generic failure.

This makes stage ownership explicit: the child script decides whether its result authorizes continuation; `main.ps1` orchestrates that decision and does not infer severity from warning text alone.

## Diagnostics

Each stage runs in a separate Windows PowerShell 5.1 process. A non-zero exit code is a hard pipeline stop. When a stage fails, `main.ps1` prints the corresponding `WARN` and `ERROR` entries from its log, including details that may not have been visible because the stage progress bar uses an in-place terminal row.

The shared console/progress libraries clear that active row before normal output, so progress updates cannot visually concatenate with `STEP`, `WARN`, or `FAIL` messages.

## Regression protocol

The intended clean-environment regression loop is:

1. Delete the target installation SSD state.
2. Remove the local Devintosh clone.
3. Clone the repository again.
4. Run `main.ps1 -Force -StopOnWarning` as Administrator.
5. Treat the first non-zero exit code as the current regression boundary. Advisory `[WARN]` entries from a stage returning `0` are recorded and displayed, but do not constitute a boundary.
6. Correct the stage without weakening a validation gate or bypassing rollback.
7. Repeat from a clean environment.
8. Continue to boot/EFI/Clover investigation only after the pipeline reaches the final `prepare-boot-disk.ps1` target-disk prompt with no invalid state reported by prior stages.

The final disk stage remains interactive and destructive. It must continue to require explicit target-disk selection and confirmation.
