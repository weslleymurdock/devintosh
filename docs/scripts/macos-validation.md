# Native macOS validation

`scripts/macos/collect-validation.sh` is the native macOS evidence collector. It is read-only and does not modify OpenCore, NVRAM, ACPI, USB mappings, audio settings, network settings or kext configuration.

`scripts/import-macos-validation.ps1` is the Windows-side importer. It verifies the manifest, privacy flags and SHA-256 evidence manifest, then stores the evidence under `build/opencore/macos-validation` and creates `build/opencore/macos-validation-report.json`.

## Workflow

1. Boot the generated OpenCore configuration far enough to run macOS.
2. Copy `scripts/macos/collect-validation.sh` to the running macOS system.
3. Run it from Terminal:

```bash
chmod +x collect-validation.sh
./collect-validation.sh
```

4. The collector creates a timestamped directory on the Desktop and a ZIP beside it.
5. Perform the runtime checks listed in `VALIDATION-CHECKLIST.md`.
6. Explicitly record only the checks that really passed. For example:

```bash
cd ~/Desktop/devintosh-macos-validation-YYYYMMDD-HHMMSS
./finalize-validation.sh --gpu --smbios --network --audio --kexts
```

7. `finalize-validation.sh` updates `validation-results.json`, regenerates `SHA256SUMS`, and recreates the ZIP.
8. Copy the final ZIP to the Windows Devintosh workspace.
9. Import it with:

```powershell
.\scripts\import-macos-validation.ps1 -BundlePath 'C:\path\devintosh-macos-validation-YYYYMMDD-HHMMSS.zip' -Force
```

The importer requires administrator privileges because the project pipeline uses the same safety contract as the other stages.

## Evidence model

The collector captures:

- macOS and kernel versions;
- hardware/model information;
- Graphics/Displays and Metal observations;
- USB topology through System Information and IORegistry;
- audio devices;
- network controllers/interfaces, with MAC addresses redacted;
- ACPI IORegistry information;
- PCI/IORegistry information;
- loaded kexts;
- disk inventory;
- NVRAM and effective boot arguments, with unique identifiers redacted.

Every evidence file and the explicit validation result file is covered by `SHA256SUMS`. The importer refuses malformed or tampered bundles.

## Runtime validation is explicit

Inventory is not treated as proof of compatibility. The collector initializes every capability to `false`. `finalize-validation.sh` is the only supported way to turn a capability marker on in the generated bundle.

A capability becomes `Validated` only when its explicit marker is true. Otherwise it remains `NeedsValidation`.

The importer intentionally does not infer compatibility from the presence of a device, a loaded kext, a Metal string, or an IORegistry entry.

## Privacy

The bundle is marked privacy-redacted and the collector removes common serial-number, UUID and MAC-address representations. Do not manually add real SMBIOS serials, MLB values, ROM values or other unique identifiers to the evidence bundle.

## What must be tested

### GPU
Confirm display output, hardware acceleration/Metal, stable graphics and sleep/wake when required. GPU compatibility should not be inferred solely from PCI identity.

### SMBIOS
Confirm the selected model is the intended candidate. Unique SMBIOS values remain outside the generic repository pipeline.

### ACPI
Confirm expected devices and power-management behaviour. Repeated ACPI errors or broken sleep/wake require investigation before declaring the capability validated.

### USB
Confirm all required physical ports and devices. Validate the topology rather than generating a map from Windows controller information alone. macOS-side enumeration is required because port mapping depends on how macOS enumerates the controller.

### Network
Confirm the intended wired/wireless interface provides connectivity and behaves correctly after relevant power-state transitions.

### Audio
Confirm intended input/output devices, including microphone support when required. Do not promote a layout ID merely because the codec is recognized; a working layout must be tested.

### Kexts
Confirm expected third-party kexts load without recurring kernel faults attributable to them.

## Readiness integration

The imported report is evidence for the next readiness stage. It does not mutate `config.plist` and does not itself apply any hardware-specific configuration.

The intended progression is:

```text
Windows resolution
        |
        v
conservative OpenCore candidate
        |
        v
native macOS boot
        |
        v
collect-validation.sh
        |
        v
runtime tests
        |
        v
finalize-validation.sh
        |
        v
import-macos-validation.ps1
        |
        v
future validation application stage
        |
        v
readiness.ps1 -> Ready
```

A future application stage should consume these reports and only promote individual capability states when explicit evidence and validation results agree. It must preserve the hardware-agnostic rule and never create SMBIOS unique identifiers or guessed hardware-specific patches.
