# acquire-opencore-drivers.ps1

Acquires firmware drivers required by the generated OpenCore configuration.

## Purpose

`build-opencore.ps1` stages the OpenCore release payload, but `HfsPlus.efi` is an Apple firmware driver maintained in Acidanthera's `OcBinaryData` repository rather than being treated as a normal OpenCore release payload. The first-boot configuration may reference `HfsPlus.efi`, so the driver must exist physically under `EFI/OC/Drivers` before boot.

This script:

1. requires an existing generated OpenCore tree;
2. downloads `HfsPlus.efi` from a pinned `OcBinaryData` commit;
3. verifies its SHA-256 digest;
4. stages it as `build/efi/EFI/OC/Drivers/HfsPlus.efi`;
5. writes a non-binary acquisition manifest;
6. never commits the binary to the repository.

The current source is pinned to commit `e74e533d8f89c1d5014cfb47c185502bf415741f` and expected SHA-256 `5887bd60c36d567be1274873966356b17fddc7742df3c55fb78e1071b5ecbfed`.

## Usage

```powershell
.\scripts\acquire-opencore-drivers.ps1 -Force
```

Run this after `build-opencore.ps1` and before configuration/validation.

## Why it is required

The generated OpenCore configuration can contain a `UEFI/Drivers` entry for `HfsPlus.efi`. OpenCore resolves that entry relative to `EFI/OC/Drivers`; if the file is absent, OpenCore stops with a critical error such as `OC: Driver HfsPlus.efi ... cannot be found`.

`HfsPlus.efi` is needed for HFS+ filesystem access used by macOS Recovery and installer media.

## Reproducibility and licensing

The script pins the upstream commit and SHA-256 so the downloaded binary is deterministic. The repository stores only the acquisition metadata; it does not redistribute the Apple binary itself. The upstream source is Acidanthera's public `OcBinaryData` repository.
