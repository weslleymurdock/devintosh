# resolve-usb.ps1

## Purpose

Resolves USB controller capability profiles from the live hardware inventory without generating or applying a macOS USB port map.

The stage is deliberately hardware-agnostic. Hardware-specific knowledge lives in `config/hardware/usb/*.json`; the PowerShell implementation does not contain controller-specific branches.

## Inputs

- `build/opencore/hardware-detected.json`, produced by `configure-opencore-hardware.ps1`.
- `config/hardware/usb/**/*.json`, containing declarative controller profiles.

A profile may match USB PnP identities using vendor, device and subsystem IDs. The current Intel xHCI profile identifies Device ID `7AE0` and declares that macOS-side port validation is required.

## Output

`build/opencore/usb-resolution.json` contains:

- matched profile IDs;
- resolved controller strategy;
- validation requirements;
- unresolved capabilities;
- safety warnings;
- explicitly prohibited/generated artifacts.

The report is written transactionally and an existing report is backed up before replacement.

## Safety model

Windows PnP data cannot safely be converted into a macOS USB port map. The two operating systems expose different topology and port semantics. Therefore this stage never invents:

- USB port maps;
- USB topology patches;
- `XhciPortLimit` bypasses;
- ACPI USB patches;
- kext selection based solely on Windows driver names or versions.

When a controller profile matches but requires native macOS evidence, the result is `NeedsValidation`, not failure. When no USB capability profile matches, the result is `NeedsProfile`.

`XhciPortLimit` is intentionally not enabled automatically; a limit bypass is not a replacement for a validated USB map.

## Transaction and rollback

The stage uses the shared transaction and rollback libraries. If report generation fails, the previous report is restored, or the newly created report is removed. Successful completion commits the transaction.

## Usage

From an elevated PowerShell session:

```powershell
Set-Location <devintosh-repository>
.\scripts\resolve-usb.ps1
```

Use `-Force` when intentionally replacing an existing generated report:

```powershell
.\scripts\resolve-usb.ps1 -Force
```

## Expected state for unsupported/partially validated hardware

The script must not reject a host merely because it is different from the developer's machine. Unknown USB hardware remains `NeedsProfile`; recognized hardware that needs macOS-side topology validation remains `NeedsValidation`.

No `config.plist` mutation is performed by this stage.
