# Transactional pipeline orchestration architecture

`main.ps1` is the single-call orchestrator for the Windows-side Devintosh preparation pipeline while the individual scripts remain independently executable stages.

## Entry point

```powershell
.\main.ps1
```

For clean regression testing, use:

```powershell
.\main.ps1 -Force -StopOnWarning
```

`-Force` is passed to non-destructive stages that expose it. It does not bypass Windows disk protection or the final destructive disk confirmation.

`-StopOnWarning` enables the explicit blocking-warning contract. It does **not** turn every `[WARN]` log entry into a failure. Exit code `9` is reserved for a stage that explicitly classifies a warning as blocking.

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
    -> prepare-boot-disk.ps1
```

`main.ps1` computes the global step count dynamically from the static `$totalSteps` declaration of every stage. The final disk stage is included in that aggregate, so progress never resets between stages.

`apply-smbios.ps1` is **not** a missing stage from the clean first-boot pipeline. It is intentionally a separate post-validation operation because it requires an explicit, externally validated SMBIOS selection manifest. The clean first-boot path instead uses `resolve-smbios.ps1` followed by `bootstrap-smbios.ps1`, which creates a synthetic local identity solely for first-boot testing. A production Apple identity must later be supplied through the explicit SMBIOS application workflow.

## Fail-fast model

Every stage executes in an isolated Windows PowerShell 5.1 child process. A non-zero exit code stops the pipeline immediately; later stages are never invoked.

The exit-code contract is:

| Exit code | Classification | Orchestration behavior |
|---:|---|---|
| `0` | Success | Continue. Advisory `[WARN]` entries remain non-blocking. |
| `1`-`8` | Failure / invalid required state | Stop immediately and preserve the code. |
| `9` | Explicit blocking warning | Stop immediately. |

`main.ps1` never infers severity from warning text. The child stage owns the classification.

## Transaction model

Each mutating stage owns its transaction and rollback actions. `main.ps1` does not attempt to undo a successfully committed earlier stage when a later stage fails.

```text
START STAGE TRANSACTION
    |
    +-- validate / prepare / acquisition / configuration / resolution stages
    +-- validate-opencore.ps1
    +-- readiness.ps1
    |
    +-- prepare-boot-disk.ps1 (interactive + destructive final stage)
```

A failure before commit rolls back the state owned by that stage. Rollback failure takes precedence in the returned exit code.

## Readiness safety gate

`readiness.ps1` is a conservative pre-destructive gate. It requires the generated reports, generated `build/efi/EFI/OC/config.plist`, and a valid final `ocvalidate` result before the pipeline can reach disk preparation.

A missing or malformed required artifact is a **hard failure**, not merely a report status. This distinction is essential: a readiness report with status `Blocked` must never allow `prepare-boot-disk.ps1` to proceed to destructive confirmation.

`NeedsProfile` and `NeedsValidation` remain representable as advisory/deferred states during clean regression. They do not cause the generic pipeline to invent hardware-specific configuration.

## OpenCore configuration chain

The generated `config.plist` is created by `configure-opencore.ps1`, then consumed by `apply-opencore-profiles.ps1`, `bootstrap-smbios.ps1`, and `configure-first-boot.ps1`. `validate-opencore.ps1` subsequently validates the final generated artifact directly with the pinned `ocvalidate` utility and checks first-boot semantic prerequisites, including non-empty SMBIOS data and staged `HfsPlus.efi`.

The profile stage is exposed through a compatibility wrapper. The wrapper must explicitly forward the bound `-Force` parameter to its implementation; named parameters are not automatically propagated through the PowerShell `$args` collection. The implementation also converts otherwise-unclassified exceptions into a non-zero failure so a broken profile application cannot silently authorize later stages.

## Pinned firmware driver integrity

`acquire-opencore-drivers.ps1` pins both the Acidanthera `OcBinaryData` source commit and the SHA-256 digest of `Drivers/HfsPlus.efi`. The currently pinned source is commit `e74e533d8f89c1d5014cfb47c185502bf415741f`, and the verified digest is:

```text
a55b5fff36578864ba6792c4c6369c71f6f35b61dd5a853ddf8583cd36c31d8f
```

The binary remains a build artifact and is not committed to Devintosh. Any digest mismatch remains exit code `7`; the pipeline never accepts an alternate binary merely because it is structurally valid.

When updating this pin, contributors must verify the exact upstream commit/path and independently record the SHA-256 of the downloaded binary in the same change. The source commit and digest must always describe the same bytes.

## Warning policy

Warning severity is owned by the stage that produced the warning. For example, `prepare.ps1` may report deferred hardware or firmware conditions while returning `0`; later profile/resolution stages remain responsible for those conditions.

A stage must not return `0` when its required output is unsafe or missing. Conversely, a deferred hardware condition that is intentionally represented by a later stage must not be promoted to a hard failure merely because it was logged as `[WARN]`.

## Hardware agnosticism

`main.ps1` contains no motherboard, CPU, GPU, SMBIOS, USB, audio, network, or kext-specific decisions. Hardware-specific behavior remains in declarative profiles/catalogs and their stage implementations. Unknown hardware remains representable as `NeedsProfile`; known but unvalidated hardware remains `NeedsValidation`.

## Final disk stage

`prepare-boot-disk.ps1` is intentionally the final interactive Windows stage. It selects only a disk that passes the active Windows boot/system-disk protection, requires an exact destructive confirmation token, creates GPT plus EFI and Recovery staging partitions, stages OpenCore, and does not modify Windows BCD.

The pipeline must reach this stage only after all non-destructive prerequisites have succeeded. In particular, missing generated OpenCore configuration or invalid readiness state must stop the pipeline **before** the destructive confirmation is presented.

## Regression contract

The clean regression objective is:

1. reset the target SSD/disk to the required zero-state;
2. remove the local repository clone;
3. clone a fresh `main`;
4. run elevated Windows PowerShell 5.1;
5. execute `.\main.ps1 -Force -StopOnWarning`;
6. stop at the first genuine non-zero stage result;
7. fix the stage without weakening its validation contract;
8. repeat from clean state.

Only after the pipeline reaches the final safe disk-selection/confirmation gate without an earlier failure should Clover/OpenCore boot behavior be investigated.
