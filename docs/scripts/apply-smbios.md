# `scripts/apply-smbios.ps1`

## Purpose

Applies an **explicitly validated** SMBIOS selection to `build/efi/EFI/OC/config.plist`.

This stage is intentionally separate from `resolve-smbios.ps1`: resolution identifies candidates, while application requires a local selection manifest containing the complete identity and an explicit `validated=true` declaration.

## Safety contract

The script never:

- selects a Mac model automatically;
- generates serial numbers, MLB, UUID, or ROM values;
- stores unique SMBIOS identifiers in source-controlled files;
- applies an identity without an explicit validation declaration.

The five fields applied are:

- `PlatformInfo -> Generic -> SystemProductName`
- `PlatformInfo -> Generic -> SystemSerialNumber`
- `PlatformInfo -> Generic -> MLB`
- `PlatformInfo -> Generic -> SystemUUID`
- `PlatformInfo -> Generic -> ROM`

## Selection manifest

The manifest is local/generated state and must not be committed. Its minimum shape is:

```json
{
  "validated": true,
  "source": "external validation reference",
  "productName": "RealMacModel,1",
  "systemSerialNumber": "validated serial",
  "mlb": "validated MLB",
  "systemUuid": "00000000-0000-0000-0000-000000000000",
  "rom": "001122334455"
}
```

The values above are illustrative only and must never be copied into a real configuration.

`validated=true` is mandatory. `source` is mandatory. UUID must be canonical hexadecimal UUID format and ROM must contain exactly 6 bytes.

If `smbios-resolution.json` contains candidates, the selected `productName` must also exist in that candidate set. This prevents a validated manifest from silently applying a model unrelated to the current resolution result.

## Transaction and rollback

The stage starts the shared transaction mechanism before modifying state.

Before changing `config.plist` it creates a timestamped backup under `build/backups/smbios/` and registers a rollback action. If any subsequent operation fails, including `ocvalidate`, the previous `config.plist` is restored.

The configuration is written through a temporary file and moved into place only after serialization succeeds.

The transaction is committed only after:

1. the explicit selection has passed local validation;
2. the configuration has been modified successfully;
3. the pinned OpenCore 1.0.7 validation stage succeeds;
4. the application report has been written.

## Validation gate

The script invokes `scripts/validate-opencore.ps1`, which validates against the project's pinned OpenCore 1.0.7 release. A non-zero validation result aborts the transaction and triggers rollback.

## Usage

This stage is intentionally not usable with the current repository state until a separately validated selection manifest exists:

```powershell
.\scripts\apply-smbios.ps1 -SelectionPath .\build\opencore\smbios-selection.json
```

Use `-Force` only when replacing an existing SMBIOS identity with another explicitly validated selection:

```powershell
.\scripts\apply-smbios.ps1 -SelectionPath .\build\opencore\smbios-selection.json -Force
```

## Output

On success:

- `build/efi/EFI/OC/config.plist` contains the validated SMBIOS identity;
- `build/opencore/smbios-application-report.json` records that the configuration was applied and validated;
- the unique identifiers remain outside source control.

On failure, the script returns the project exit code and attempts automatic rollback.

## Hardware agnosticism

There are no motherboard, CPU, GPU, Wi-Fi, Ethernet, or Apple-model branches in PowerShell. The selected product and identity are inputs from a separately validated manifest. The script only enforces the safety contract and coordinates the transaction.
