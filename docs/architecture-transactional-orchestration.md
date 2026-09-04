# Transactional pipeline orchestration architecture

`main.ps1` is the single-call orchestrator for the Windows-side preparation pipeline while the individual scripts remain independently executable stages.

## Entry point

```powershell
.\main.ps1
```

For clean regression testing, use:

```powershell
.\main.ps1 -Force -StopOnWarning
```

`-Force` is passed only to non-destructive stages that expose it. It does not bypass Windows disk protection or the final destructive disk confirmation.

`-StopOnWarning` enables the explicit blocking-warning contract. It does **not** turn every `[WARN]` log entry into a failure. A child stage that returns exit code `0` has explicitly authorized pipeline continuation; warnings produced with that successful result are advisory/deferred and remain visible in diagnostics. Exit code `9` is reserved for a stage that completed its operation but classified a warning as blocking.

## Fail-fast model

Every stage executes in an isolated Windows PowerShell 5.1 child process. A non-zero exit code stops the pipeline immediately; later stages are never invoked.

After a stage exits, `main.ps1` captures `$LASTEXITCODE` immediately and also reads the stage log to surface `WARN`/`ERROR` diagnostics. The exit code is authoritative for continuation; log severity alone is not. This distinction prevents a deferred hardware or firmware warning from incorrectly stopping the pipeline while preserving fail-fast behavior for an actual invalid state.

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

A warning that is explicitly classified as blocking uses exit code `9`. With `-StopOnWarning`, `main.ps1` reports it as a blocking warning and stops before the next stage. A stage returning exit code `0` is allowed to continue even when its log contains advisory `[WARN]` entries.

## Warning policy

Warning severity is owned by the stage that produced the warning, not inferred by `main.ps1` from the warning text.

The shared exit-code contract is:

| Exit code | Classification | Orchestration behavior |
|---:|---|---|
| `0` | Success | Continue. Any WARN entries are advisory/deferred. |
| `1`-`8` | Failure / invalid required state | Stop immediately and preserve the code. |
| `9` | Blocking warning | Stop immediately; with `-StopOnWarning`, report the condition explicitly as a blocking warning. |

This keeps stage semantics deterministic. A stage must not return `0` for a condition that makes its output unsafe for the next stage. Conversely, a stage must not use a warning merely to describe a condition that a later stage is responsible for resolving.

For example, `prepare.ps1` currently reports these advisory conditions while returning exit code `0`:

- RX 550 Lexa device `699F` may require a supported Polaris identity spoof. GPU spoof/profile resolution is deferred to the OpenCore hardware-resolution stages.
- No target disk is selected. The preparation stage is intentionally non-destructive and target selection belongs to the final disk-preparation stage.
- Secure Boot is disabled. The preparation stage records firmware state and does not modify UEFI settings; boot/firmware policy is handled separately.

These warnings are therefore displayed but do not stop the clean regression pipeline.

## Console diagnostics

The shared progress bar uses an in-place terminal row. Before this change, subsequent `Write-Host` messages could be appended to that row, producing output such as a progress bar immediately followed by `STEP 02` and making intermediate WARN states difficult to see.

The console/progress libraries now clear the active ANSI row before normal step/result output. The progress line also clears stale characters before redraw. This preserves the existing visual style while preventing terminal-overlap artifacts.

## Stage contract

Every stage participating in orchestration must:

- expose a deterministic exit code;
- use exit code `0` only when the next stage may safely consume its result;
- use exit code `9` only when a warning is explicitly classified as blocking;
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

The orchestrator is implemented with exit-code-based warning semantics. The immediate regression-validation objective is to execute a clean clone with `-Force -StopOnWarning`, allow advisory/deferred warnings to pass, and require the first genuinely non-zero stage result to stop the pipeline. The run should ultimately reach the final `prepare-boot-disk.ps1` safe target-disk selection/confirmation prompt. Only after that baseline is stable should boot/EFI/Clover behavior be investigated.
