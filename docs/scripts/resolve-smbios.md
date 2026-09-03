# `scripts/resolve-smbios.ps1`

## Purpose

Resolves SMBIOS **capability profiles and candidate Mac product models** from the live Windows hardware inventory without generating or persisting a machine identity.

This is deliberately a separate stage from applying SMBIOS values to `config.plist`.

## Why the stage is conservative

Windows hardware facts do not safely determine a unique Apple SMBIOS identity. In particular, the following values must not be invented by the generic installer:

- `PlatformInfo -> Generic -> SystemProductName`
- `PlatformInfo -> Generic -> SystemSerialNumber`
- `PlatformInfo -> Generic -> MLB`
- `PlatformInfo -> Generic -> SystemUUID`
- `PlatformInfo -> Generic -> ROM`

OpenCore requires `SystemProductName` to be a real Mac model, while the remaining values are identity data. The project therefore treats SMBIOS selection as a validation boundary rather than guessing a model from CPU or motherboard names.

## Inputs

- `build/opencore/hardware-detected.json`
- `config/hardware/smbios/*.json`

A profile is declarative. It contains a hardware match rule and an optional `opencore.smbios.candidates` collection.

Example shape:

```json
{
  "id": "smbios-example",
  "match": {
    "cpuVendor": "GenuineIntel"
  },
  "capabilities": {
    "smbios": true,
    "requiresSmbiosValidation": true
  },
  "opencore": {
    "smbios": {
      "policy": "validation-required",
      "candidates": [
        {
          "productName": "MacModel,1",
          "confidence": "candidate",
          "requiresValidation": true,
          "rationale": "Profile-specific rationale."
        }
      ]
    }
  }
}
```

The example is illustrative; profiles must only contain candidates supported by project validation evidence.

## Outputs

`build/opencore/smbios-resolution.json` contains:

- resolution status;
- matched profiles;
- deduplicated SMBIOS candidates;
- candidate confidence/rationale;
- warnings;
- explicitly withheld identity fields.

Possible status values are:

- `NeedsProfile` — no SMBIOS capability profile matched the hardware;
- `NeedsValidation` — a profile matched, but SMBIOS identity still requires validation.

There is intentionally no automatic `Resolved` state in this stage. A future application stage must establish that the product model and identity data are valid before writing them to `config.plist`.

## Rollback

The report is written transactionally. If a previous `smbios-resolution.json` exists, it is backed up under `build/backups/smbios/` before replacement. If the transaction fails, the previous report is restored through the shared rollback mechanism.

The script does **not** modify `config.plist`.

## Usage

Run after hardware detection:

```powershell
.\scripts\configure-opencore-hardware.ps1
.\scripts\configure-opencore.ps1
.\scripts\resolve-smbios.ps1
```

Inspect:

```powershell
Get-Content .\build\opencore\smbios-resolution.json -Raw
```

## Hardware-agnostic guarantees

The PowerShell implementation contains no motherboard, CPU, GPU, Wi-Fi, Ethernet, or Apple model identifiers. Those decisions belong exclusively to declarative profiles.

Unknown hardware is represented as `NeedsProfile`; known hardware without sufficient SMBIOS evidence remains `NeedsValidation`.

## Safety boundary

This script does not generate serial numbers, MLB values, UUIDs, or ROM values. It also does not silently select an Apple model merely because a CPU generation resembles one used by an existing Hackintosh guide.

That separation is intentional: the next SMBIOS application stage can consume this report only after a validated profile explicitly authorizes the required identity data.
