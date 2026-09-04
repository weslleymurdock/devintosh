# acquire-opencore-drivers.ps1

Acquires firmware drivers required by the generated OpenCore configuration.

## Purpose

`build-opencore.ps1` stages the OpenCore release payload, but `HfsPlus.efi` is an Apple firmware driver maintained in Acidanthera's `OcBinaryData` repository rather than being treated as a normal OpenCore release payload. The first-boot configuration may reference `HfsPlus.efi`, so the driver must exist physically under `EFI/OC/Drivers` before boot.

This script:

1. requires an existing generated OpenCore tree;
2. downloads `HfsPlus.efi` from a pinned `OcBinaryData` commit;
3. validates the downloaded file as a PE image;
4. verifies its SHA-256 digest;
5. stages it as `build/efi/EFI/OC/Drivers/HfsPlus.efi`;
6. writes a non-binary acquisition manifest;
7. never commits the binary to source control.

## Current integrity pin

The current reproducible pin is:

```text
Repository: Acidanthera/OcBinaryData
Path:       Drivers/HfsPlus.efi
Commit:     e74e533d8f89c1d5014cfb47c185502bf415741f
SHA-256:    a55b5fff36578864ba6792c4c6369c71f6f35b61dd5a853ddf8583cd36c31d8f
```

The commit/path and digest are a single integrity contract. The digest was corrected after the previously recorded value was shown to disagree with the bytes served from the pinned upstream commit. The validation gate remains strict: any other digest is an integrity failure with exit code `7`.

When changing the pin, contributors must verify the exact upstream commit and path and calculate the SHA-256 of those exact downloaded bytes. Do not update the digest independently of the source commit.

## Usage

```powershell
.\scripts\acquire-opencore-drivers.ps1 -Force
```

Run this after `build-opencore.ps1` and before configuration/validation stages that consume the driver.

## Validation and exit codes

The download is retried up to three times when acquisition or PE-header validation fails. The SHA-256 verification is a hard integrity gate and does not accept a different digest.

The script follows the shared Devintosh exit-code contract:

| Exit code | Meaning |
|---:|---|
| `0` | Driver acquired, verified, and staged successfully. |
| `3` | Administrator privileges are unavailable. |
| `4` | Required OpenCore staging directory does not exist. |
| `5` | Rollback failed while restoring the previous staging state. |
| `7` | Downloaded `HfsPlus.efi` failed SHA-256 integrity verification. |
| `1` | Other acquisition, validation, staging, or rollback failure. |

A SHA-256 mismatch is therefore never an advisory warning: the script returns exit code `7` and `main.ps1` must stop before any subsequent stage consumes the untrusted binary.

## Why it is required

The generated OpenCore configuration can contain a `UEFI/Drivers` entry for `HfsPlus.efi`. OpenCore resolves that entry relative to `EFI/OC/Drivers`; if the file is absent, OpenCore stops with a critical error such as `OC: Driver HfsPlus.efi ... cannot be found`.

`HfsPlus.efi` is needed for HFS+ filesystem access used by macOS Recovery and installer media.

## Reproducibility and licensing

The script pins the upstream commit and SHA-256 so the downloaded binary is deterministic. The repository stores only the acquisition metadata; it does not redistribute the Apple binary itself. The upstream source is Acidanthera's public `OcBinaryData` repository.
