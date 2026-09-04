# Transactional pipeline orchestration architecture

`main.ps1` is now the single-call orchestrator for the Windows-side preparation pipeline while the individual scripts remain independently executable stages.

## Entry point

```powershell
.\main.ps1
```

For clean regression testing, use:

```powershell
.\main.ps1 -Force -StopOnWarning
```

`-Force` is passed only to non-destructive stages that expose it. It does not bypass Windows disk protection or the final destructive disk confirmation.

`-StopOnWarning` is an additional regression gate. Each completed stage is checked for `[WARN]` entries in its stage log. With the switch enabled, any warning stops the pipeline even when the child process returned exit code `0`. The two switches are independent and may be combined.

## Fail-fast model

Every stage executes in an isolated Windows PowerShell 5.1 child process. A non-zero exit code stops the pipeline immediately; later stages are never invoked.

After a stage exits, `main.ps1` also reads the stage log and surfaces `WARN`/`ERROR` diagnostics. This is intentional: several stages use file logging for diagnostics while the progress bar uses an in-place terminal row, so relying only on visible console text can hide the actual state.

The final `prepare-boot-disk.ps1` stage remains interactive and is never given `-Force` or an automatically selected disk.

## Transaction model

The pipeline uses stage-level transaction/rollback semantics:

```text
START STAGE TRANSACTION
    |
    +-- validate.ps1
    +-- prepare.ps1
    +-- ...
    +-- validate-opencore.ps1
    +-- readiness.ps1
    |
    +-- prepare-boot-disk.ps1 (interactive/destructive final stage)
```

### Failure before commit

If a mutating stage fails:

1. Stop the pipeline immediately.
2. Execute that stage's registered rollback actions in reverse order.
3. Restore the state owned by the failed stage.
4. Preserve failure and rollback diagnostics.
5. Return the most relevant project exit code, using the rollback-failure code when restoration itself fails.

A warning is not silently converted to success when `-StopOnWarning` is active. The stage has already completed its own transaction, so the warning gate stops before any subsequent stage can consume the potentially unsafe state.

## Warning policy

Warnings remain allowed by default for backward compatibility with normal exploratory execution. The explicit `-StopOnWarning` mode is intended for clean-environment regression validation, where every stage must produce a warning-free state before the next stage is allowed to run.

Examples of warning-producing conditions already represented by the stages include unresolved hardware capability profiles, ambiguous multiple profile matches, unavailable firmware information, and kexts that are intentionally present but disabled pending validation. These are not equivalent to a hard failure in normal mode, but they are gates in strict regression mode.

## Console diagnostics

The shared progress bar uses an in-place terminal row. Before this change, subsequent `Write-Host` messages could be appended to that row, producing output such as a progress bar immediately followed by `STEP 02` and making intermediate WARN states difficult to see.

The console/progress libraries now clear the active ANSI row before normal step/result output. The progress line also clears stale characters before redraw. This preserves the existing visual style while preventing terminal-overlap artifacts.

## Stage contract

Every stage participating in orchestration must:

- expose a deterministic exit code;
- fail explicitly instead of silently accepting an invalid state;
- register rollback actions for mutations it performs;
- write generated artifacts transactionally where practical;
- avoid hardware-specific PowerShell branches;
- leave `NeedsProfile` / `NeedsValidation` states representable;
- never claim a commit when a required validation gate failed;
- log WARN and ERROR diagnostics using the shared logging contract.

## Rollback ownership

The shared `scripts/lib/rollback.ps1` remains the primitive for stage-level rollback. `main.ps1` does not attempt to reverse a successfully completed stage merely because a later stage failed. Each stage owns the inverse of its own mutations.

## Validation gates

`ocvalidate` remains a hard validation gate for generated `config.plist` state. The readiness stage remains conservative: missing or malformed inputs, unresolved capabilities, and insufficient validation evidence must not become `Ready` by inference.

`-StopOnWarning` is deliberately an orchestration-level gate and does not replace the semantic validation performed by individual stages.

## Hardware agnosticism

`main.ps1` contains no motherboard, CPU, GPU, SMBIOS, USB, audio, network, or kext-specific decisions. Those decisions remain in declarative profiles/catalogs and stage implementations.

## Current status

The orchestrator is implemented. The immediate regression-validation objective is to execute a clean clone with `-Force -StopOnWarning` and require a warning-free pipeline through the point where `prepare-boot-disk.ps1` presents the safe target-disk selection/confirmation prompt. Only after that baseline is stable should boot/EFI/Clover behavior be investigated.
