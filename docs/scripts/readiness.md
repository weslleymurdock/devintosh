# Readiness gate

`readiness.ps1` is the conservative pre-boot gate for the generated Devintosh/OpenCore state.

## Purpose

The gate consolidates the outputs of the hardware, GPU, SMBIOS, ACPI, USB, network, audio and kext stages and verifies the final `config.plist` validation report. It does not configure hardware and does not generate missing data.

## Invocation

```powershell
.\scripts\readiness.ps1 -Force
```

`-Force` replaces the previous generated readiness report after creating a timestamped backup under `build/backups/readiness/`.

## Inputs

The gate expects the generated reports from the preceding pipeline stages, including:

- `build/opencore/hardware-detected.json`
- `build/opencore/configuration-report.json`
- `build/opencore/gpu-resolution.json`
- `build/opencore/smbios-resolution.json`
- `build/opencore/acpi-resolution.json`
- `build/opencore/usb-resolution.json`
- `build/opencore/network-resolution.json`
- `build/opencore/audio-resolution.json`
- `build/opencore/kext-resolution.json`
- `build/opencore/kext-assets.json`
- `build/opencore/kext-composition-report.json`
- `build/opencore/validation-report.json`
- `build/efi/EFI/OC/config.plist`
- `config/versions/sequoia.json`

Malformed or missing required inputs are `Blocked`; they are never silently ignored.

## Decision states

| State | Meaning |
|---|---|
| `Ready` | Every required capability is resolved and the final generated config passed the pinned `ocvalidate`. |
| `NeedsValidation` | No capability is missing a profile, but one or more capabilities still require explicit validation. |
| `NeedsProfile` | At least one capability has no matching profile or remains unresolved. |
| `Blocked` | A required report/configuration artifact is missing, malformed, has an unknown state, or final validation is not valid. |

The script itself returns exit code `0` when the gate was evaluated successfully, even when the resulting readiness state is `NeedsValidation` or `NeedsProfile`. A script execution failure uses the project-wide non-zero exit codes.

## Conservative precedence

The decision order is:

```text
Blocked
   |
   v
NeedsProfile
   |
   v
NeedsValidation
   |
   v
Ready
```

This prevents a validation warning from masking an unresolved hardware capability and prevents a missing/invalid artifact from being interpreted as a configuration that merely needs validation.

## OpenCore validation

The final validation report must have status `Valid`, exit code `0`, and the same OpenCore version declared by `config/versions/sequoia.json`. The gate therefore protects the pinned OpenCore 1.0.7 validation path from accidental version drift.

## Safety policy

`readiness.ps1` is report-only. It never:

- modifies `config.plist`;
- writes SMBIOS serial, MLB, UUID or ROM values;
- enables GPU spoofing or GPU DeviceProperties;
- adds ACPI patches or SSDTs;
- creates USB port maps;
- selects audio layout IDs or routing;
- configures network interfaces;
- downloads or replaces kexts;
- changes firmware, disks, partitions or boot configuration.

The gate is intentionally independent from any one machine. A new supported hardware profile can move a capability from `NeedsProfile` to `NeedsValidation` without adding hardware-specific PowerShell logic.

## Transaction and rollback

The generated readiness report is written transactionally. If a previous report exists and `-Force` is used, the old report is backed up before replacement and registered with the shared rollback stack. A write failure restores the previous report; if no previous report existed, the newly created report is removed.

The gate itself does not establish a new hardware/configuration baseline. The repository commit containing this implementation is the source-control safety checkpoint; runtime rollback remains limited to the generated readiness artifact.
