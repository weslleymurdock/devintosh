# resolve-acpi.ps1

## Purpose

Resolves the ACPI capability profile for the detected Windows hardware without generating or applying ACPI changes.

The stage is intentionally conservative: Windows PnP identities are useful for selecting a declarative profile, but they are not sufficient evidence to synthesize a macOS DSDT/SSDT or an OpenCore ACPI patch.

## Usage

```powershell
Set-Location <repository>
.\scripts\resolve-acpi.ps1
```

Use `-Force` to replace an existing generated report while preserving the previous report through the shared backup/rollback mechanism:

```powershell
.\scripts\resolve-acpi.ps1 -Force
```

The script requires an elevated PowerShell 5.1 session and requires `build/opencore/hardware-detected.json`, normally produced by `configure-opencore-hardware.ps1`.

## Pipeline position

```text
configure-opencore-hardware.ps1
        |
        v
  resolve-acpi.ps1
        |
        v
  [native macOS ACPI validation]
        |
        v
  [future validated ACPI application stage]
        |
        v
  validate-opencore.ps1
```

## Hardware-agnostic behavior

ACPI profiles live under `config/hardware/acpi/`. A profile may match CPU/platform facts and declare a validation strategy, but it must not turn Windows device names into guessed ACPI patches.

The current generic Intel profile therefore resolves to `NeedsValidation`. This is expected and is not an installation failure.

Unknown hardware is reported as `NeedsProfile`, allowing the pipeline to continue to the point where additional hardware-specific knowledge is required.

## Generated state

The script writes:

- `build/opencore/acpi-resolution.json`

The report contains the matched profiles, declared strategy, validation requirements, warnings and intentionally omitted artifacts.

## Intentionally not generated

This stage does **not** create:

- `ACPI -> Add` entries;
- `ACPI -> Delete` entries;
- `ACPI -> Patch` entries;
- DSDT/SSDT binaries;
- ACPI table contents;
- patches inferred from Windows PnP names or device IDs.

Any future mutating stage must consume explicit validated ACPI evidence/profile data and use the same transaction, backup, rollback and final `ocvalidate` pattern used by the other OpenCore stages.

## Transaction and rollback

The stage uses `Start-DevintoshTransaction`, `Add-DevintoshRollbackAction`, `Invoke-DevintoshRollback` and `Complete-DevintoshTransaction` from `scripts/lib/rollback.ps1`.

When replacing an existing report, the previous report is copied to `build/backups/acpi/` before the new report is committed. If any later operation fails, the previous report is restored.

## Safety invariant

A successful ACPI resolution does **not** mean that ACPI configuration is safe to apply. The success of this stage means only that the hardware has been classified into an ACPI capability profile and the required next validation state has been recorded.
