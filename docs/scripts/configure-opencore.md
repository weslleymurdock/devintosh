# `configure-opencore.ps1`

Resolves the detected hardware against declarative profiles and creates a conservative OpenCore candidate.

## Usage

```powershell
.\scripts\configure-opencore.ps1
```

## Resolution states

- `Resolved`: required capabilities have profiles and no validation gate is active.
- `NeedsValidation`: profiles exist but one or more capabilities explicitly require validation.
- `NeedsProfile`: one or more capabilities have no matching profile.

## Safety

Unknown hardware is never mapped to another machine. The resolver does not invent SMBIOS identifiers, audio layout IDs, USB maps, ACPI patches, GPU spoofing, or third-party binaries.

It writes `build/opencore/hardware-resolution.json`, `build/opencore/configuration-report.json`, and the candidate `build/efi/EFI/OC/config.plist`.
