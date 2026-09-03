# Transactional pipeline orchestration architecture

This document records the future orchestration architecture. The orchestrator is intentionally **not implemented yet**. Individual pipeline stages continue to be executed and validated manually until the complete pipeline is stable.

## Future entry point

The future `main.ps1` will provide a single-call entry point for the complete pipeline, while preserving the existing scripts as independently executable stages.

Example shape:

```powershell
.\main.ps1
```

Parameters will be passed through only where a stage requires them (for example target disk selection or an explicit validation/force mode). `main.ps1` must not contain hardware-specific rules; it is an orchestrator only.

## Transaction model

The pipeline will use a **transaction boundary** around the complete orchestration:

```text
START TRANSACTION
    |
    +-- validate.ps1
    +-- prepare.ps1
    +-- download-recovery.ps1
    +-- build-opencore.ps1
    +-- configure-opencore-hardware.ps1
    +-- configure-opencore.ps1
    +-- apply-opencore-profiles.ps1
    +-- resolve-kexts.ps1
    +-- acquire-kext-assets.ps1
    +-- compose-opencore-kexts.ps1
    +-- resolve-smbios.ps1
    +-- future ACPI / USB / Audio / GPU validation stages
    +-- validate-opencore.ps1
    |
COMMIT TRANSACTION
```

### Failure before commit

If any mutating stage fails before the transaction reaches its commit point:

1. Stop the pipeline immediately.
2. Execute registered rollback actions in reverse order.
3. Restore the state that existed before the transaction started.
4. Preserve the failure/rollback diagnostics.
5. Return the most relevant project exit code, using the existing rollback-failure code when restoration itself fails.

The transaction must never report success when rollback is incomplete.

### Success and subsequent transactions

Once the complete transaction is committed, that committed state becomes the new baseline for subsequent transactional work.

Future transactions therefore follow:

```text
COMMITTED STATE N
       |
       +-- start transaction N+1
       |
       +-- stage changes
       |
       +-- failure -> rollback to COMMITTED STATE N
       |
       +-- success -> commit STATE N+1
```

This is important because a later rollback must **not** erase a previously committed pipeline state.

## Stage contract

Every stage participating in orchestration must:

- expose a deterministic exit code;
- fail explicitly instead of silently accepting an invalid state;
- register rollback actions for mutations it performs;
- write generated artifacts transactionally where practical;
- avoid hardware-specific PowerShell branches;
- leave `NeedsProfile` / `NeedsValidation` states representable;
- never claim a commit when a required validation gate failed.

## Rollback ownership

The shared `scripts/lib/rollback.ps1` remains the primitive for stage-level rollback. The future orchestrator will add a transaction-level scope above individual stages rather than replacing the existing mechanism.

A stage must not delete or restore another stage's committed state directly. It registers the inverse of its own mutation with the active transaction.

## Validation gates

`ocvalidate` remains a hard validation gate for generated `config.plist` state. In the future orchestrated flow, the final validation must succeed before the transaction is committed.

A future stage that changes `config.plist` should preferably validate its result before allowing the outer transaction to advance. A failure must therefore be recoverable without leaving a partially applied configuration.

## Hardware agnosticism

`main.ps1` will never contain mappings such as:

- a specific motherboard model;
- a specific CPU model;
- a specific GPU Device ID;
- a specific SMBIOS selection;
- a hardcoded USB map;
- a hardcoded audio layout;
- a hardware-specific kext list.

Those decisions remain declarative profile/catalog data. The orchestrator only coordinates stages and transaction state.

## Current status

This architecture is documented only. `main.ps1` is deliberately deferred until the individual stages have been implemented and manually validated end-to-end.
