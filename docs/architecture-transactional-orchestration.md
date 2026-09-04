# Transactional pipeline orchestration architecture

`main.ps1` is the single-call orchestrator for the Windows-side Devintosh preparation pipeline while the individual scripts remain independently executable stages.

## Entry point

```powershell
.\main.ps1 -MacOSVersion sequoia -Force -StopOnWarning
```

`-Force` is passed to non-destructive stages that expose it. It does not bypass Windows disk protection or the final destructive disk confirmation.

`-StopOnWarning` enables the explicit blocking-warning contract. It does **not** turn every `[WARN]` log entry into a failure. Exit code `9` is reserved for a stage that explicitly classifies a warning as blocking.

## Central project contract

All PowerShell stages must source `scripts/lib/common.ps1`. That library loads `scripts/lib/project-context.ps1`, which is the single source of truth for shared runtime values.

The context exposes `$script:Devintosh` with four stable sections:

- `Version` — selected macOS target and source profile.
- `OpenCore` — OpenCore repository, release/version/tag, release SHA-256, tooling path, and pinned source commit.
- `Recovery` — Recovery board ID, MLB, OS type, pinned chunklist SHA-256, canonical build paths, and persistent cache paths.
- `Paths` — repository, build, log, backup, EFI, OpenCore, manifest, and inventory paths.

`main.ps1` selects the target through `DEVINTOSH_MACOS_VERSION` before launching isolated child processes. Child stages reconstruct the exact same contract from the source-controlled profile. Stages must not independently parse `config/versions`, calculate the Recovery cache location, or duplicate version/path constants.

The environment variable `DEVINTOSH_RECOVERY_CACHE` is also exported by the central context. Its value is the root of the drive containing the repository clone plus `DevintoshRecoveryCache`. For a clone at `E:\dev\devintosh`, the cache is `E:\DevintoshRecoveryCache`. This cache is deliberately outside the repository and therefore survives a clean re-clone.

See [`scripts/lib-project-context.md`](scripts/lib-project-context.md) for the complete contract.

## Current pipeline

The implemented `main.ps1` pipeline is ordered as follows:

```text
validate.ps1
    -> prepare.ps1
    -> download-recovery.ps1
    -> build-opencore.ps1
    -> configure-opencore-hardware.ps1
    -> configure-opencore.ps1
    -> acquire-opencore-drivers.ps1
    -> resolve-gpu.ps1
    -> apply-opencore-profiles.ps1
    -> resolve-smbios.ps1
    -> bootstrap-smbios.ps1
    -> configure-first-boot.ps1
    -> resolve-acpi.ps1
    -> resolve-usb.ps1
    -> resolve-network.ps1
    -> resolve-audio.ps1
    -> resolve-kexts.ps1
    -> acquire-kext-assets.ps1
    -> compose-opencore-kexts.ps1
    -> validate-opencore.ps1
    -> readiness.ps1
    -> verify-boot-artifacts.ps1
    -> prepare-boot-disk.ps1
```

`main.ps1` computes the global step count dynamically from the static `$totalSteps` declaration of every stage. The final disk stage is included in that aggregate, so progress never resets between stages.

`apply-smbios.ps1` is **not** a missing stage from the clean first-boot pipeline. It is intentionally a separate post-validation operation because it requires an explicit, externally validated SMBIOS selection manifest. The clean first-boot path instead uses `resolve-smbios.ps1` followed by `bootstrap-smbios.ps1`, which creates a synthetic local identity solely for first-boot testing.

## Fail-fast model

Every stage executes in an isolated Windows PowerShell 5.1 child process. A non-zero exit code stops the pipeline immediately; later stages are never invoked.

The exit-code contract is:

| Exit code | Classification | Orchestration behavior |
|---:|---|---|
| `0` | Success | Continue. Advisory `[WARN]` entries remain non-blocking. |
| `1`-`8` | Failure / invalid required state | Stop immediately and preserve the code. |
| `9` | Explicit blocking warning | Stop immediately. |

`main.ps1` never infers severity from warning text. The child stage owns the classification.

## Recovery cache contract

`download-recovery.ps1` and its implementation use the central Recovery contract. A valid persistent cache is reused without contacting Apple's Recovery CDN. Cache reuse requires:

1. `recovery-manifest.json` exists and matches the selected target, board ID, OS type, and pinned chunklist SHA-256;
2. `BaseSystem.dmg` and `BaseSystem.chunklist` exist;
3. the local `BaseSystem.chunklist` SHA-256 matches the version profile;
4. the pinned OpenCore `macrecovery.py` verifier validates every DMG chunk locally.

If any check fails, the cache is rejected and a fresh Recovery download is performed. The fresh download is verified by `macrecovery` and the pinned chunklist SHA-256 before it is committed to the persistent cache. Only then is it copied into the repository's canonical `build/recovery` destination.

The upstream `macrecovery.py` verifier uses `os.get_terminal_size()` while printing chunk progress. When invoked as a non-interactive child process, this can fail independently of image integrity. Devintosh supplies a terminal-size shim around the upstream verifier; the downloaded verifier itself is not modified.

## Transaction model

Each mutating stage owns its transaction and rollback actions. `main.ps1` does not attempt to undo a successfully committed earlier stage when a later stage fails.

## Readiness and destructive safety gates

`readiness.ps1` is a conservative pre-boot gate. It requires generated reports, generated `build/efi/EFI/OC/config.plist`, and a valid final `ocvalidate` result.

`verify-boot-artifacts.ps1` is the final **non-destructive** gate. It verifies the exact EFI artifacts and verified Recovery payload consumed by `prepare-boot-disk.ps1`. Therefore missing `config.plist`, missing `OpenCore.efi`, missing `BOOTx64.efi`, or missing/invalid Recovery is discovered before disk selection and before any destructive confirmation token is requested.

This producer/consumer boundary is intentional: the destructive stage does not diagnose whether the build succeeded; it consumes an artifact set already proven to exist and match the selected target contract.

## OpenCore configuration chain

The generated `config.plist` is created by `configure-opencore.ps1`, then consumed by profile/bootstrap/first-boot stages. `validate-opencore.ps1` validates the final generated artifact directly with the pinned `ocvalidate` utility and checks first-boot semantic prerequisites, including non-empty SMBIOS data and schema-valid `HfsPlus.efi` driver entries.

## Pinned firmware driver integrity

`acquire-opencore-drivers.ps1` pins both the Acidanthera `OcBinaryData` source commit and the SHA-256 digest of `Drivers/HfsPlus.efi`. The binary remains a build artifact and is not committed to Devintosh. Any digest mismatch remains exit code `7`.

## Warning policy

Warning severity is owned by the stage that produced the warning. A stage must not return `0` when its required output is unsafe or missing. Conversely, a deferred hardware condition that is intentionally represented by a later stage must not be promoted to a hard failure merely because it was logged as `[WARN]`.

## Hardware agnosticism

`main.ps1` contains no motherboard, CPU, GPU, SMBIOS, USB, audio, network, or kext-specific decisions. Hardware-specific behavior remains in declarative profiles/catalogs and their stage implementations. Unknown hardware remains representable as `NeedsProfile`; known but unvalidated hardware remains `NeedsValidation`.

## Version coupling

The selected macOS profile is the contract boundary between macOS, OpenCore, and Recovery. A future target is added by creating `config/versions/<id>.json` with its own macOS identity, OpenCore release/source pin, and Recovery integrity pin. Generic scripts consume the centralized context and do not receive new hardcoded version branches.

## Regression contract

The clean regression objective is:

1. reset the target SSD/disk to the required zero-state;
2. remove the local repository clone;
3. clone a fresh `main`;
4. run elevated Windows PowerShell 5.1;
5. execute `.\main.ps1 -MacOSVersion sequoia -Force -StopOnWarning`;
6. stop at the first genuine non-zero stage result;
7. fix the stage without weakening its validation contract;
8. repeat from clean state.

A valid persistent Recovery cache may be retained because it is intentionally outside the repository. Its integrity is always revalidated before reuse.

Only after the pipeline reaches the final safe disk-selection/confirmation gate without an earlier failure should Clover/OpenCore boot behavior be investigated.
