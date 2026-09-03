# resolve-audio.ps1

## Purpose

Resolves audio capability profiles from the live Windows hardware inventory without modifying `config.plist`.

The stage is hardware-agnostic and data-driven. Windows audio identities are used only to select declarative profiles. Audio endpoints that do not expose a stable hardware identity are not guessed into a codec profile.

## Usage

```powershell
.\scripts\resolve-audio.ps1
```

Use `-Force` to replace an existing generated report after the previous report is backed up:

```powershell
.\scripts\resolve-audio.ps1 -Force
```

Run from an elevated PowerShell 5.1 session after `configure-opencore-hardware.ps1`.

## Inputs

- `build/opencore/hardware-detected.json`
- `config/hardware/audio/*.json`

Audio profiles may match vendor/device/subsystem identities and declare capability and validation requirements. They must not contain machine-specific PowerShell branches.

## Current native-audio policy

The initial codec profile identifies Realtek ALC897 devices. A match does **not** select an AppleALC layout automatically. The resolver reports `NeedsValidation` until native macOS evidence establishes a valid layout and the relevant input/output paths have been tested.

The resolver deliberately does not generate:

- AppleALC `layout-id`;
- `alcid` boot arguments;
- audio `DeviceProperties`;
- audio ACPI patches;
- routing configuration;
- kext binaries selected from Windows driver versions.

## Alternative audio transport

Alternative transports are treated as capability-level fallbacks, not as machine-specific workarounds. A Windows endpoint alone does not activate a fallback. A future validated fallback profile must explicitly declare the macOS support mechanism, prerequisites, required assets and validation evidence.

See [`../audio-fallback.md`](../audio-fallback.md).

## Output

The stage writes:

`build/opencore/audio-resolution.json`

The report contains the matched profiles, native-audio strategies, unmatched devices/endpoints, available declarative fallback profiles, validation requirements, warnings and intentionally ungenerated artifacts.

## Status semantics

- `Resolved`: a profile exists and declares no unresolved validation requirement.
- `NeedsValidation`: a known audio capability was matched, but macOS-side evidence is still required.
- `NeedsProfile`: no suitable audio capability profile matched the detected hardware.

Unmatched Windows audio endpoints do not cause failure. This is important for streaming, virtual, Bluetooth and other software-defined audio devices that cannot safely be translated into native macOS codec configuration from Windows data alone.

## Transaction and rollback

The report write is transactional. If a previous report exists and `-Force` is used, it is backed up under the shared Devintosh backup root before replacement. A failed transaction restores the previous report; a newly created report is removed on rollback.

The stage does not mutate the EFI or OpenCore configuration.

## Pipeline position

```text
resolve-acpi.ps1
    -> resolve-usb.ps1
    -> resolve-network.ps1
    -> resolve-audio.ps1
    -> resolve-smbios.ps1
```

Audio kext acquisition and `Kernel -> Add` composition remain separate stages. Native audio mutation must only occur after explicit macOS validation.
