# Kext catalog and asset pipeline

The kext layer is deliberately separate from hardware detection and OpenCore plist generation.

## Catalog

`catalog.json` contains pinned release metadata for third-party kexts:

- repository and release tag;
- exact release asset name and download URL;
- SHA-256 digest;
- SPDX license identifier;
- explicit redistributability flag;
- payload names;
- dependency graph.

Binary archives are **not** committed to the repository. They are downloaded only during the asset acquisition stage and remain generated build artifacts.

## Requirements and resolution

`core.json` declares the generic kext baseline. Hardware profiles may add entries through their `kexts` array.

A profile must not put a hardware-specific `if`/`switch` in PowerShell. Kext selection belongs in declarative profile data.

A `validation-required` hardware profile may still declare a kext. The resolver reports the kext and its validation state instead of silently treating the profile as fully validated.

Run:

```powershell
.\scripts\resolve-kexts.ps1
```

The result is written to `build/opencore/kext-resolution.json`.

## Asset acquisition

After resolution, run:

```powershell
.\scripts\acquire-kext-assets.ps1
```

The acquisition stage:

1. reads the resolved plan;
2. validates catalog metadata and HTTPS URLs;
3. downloads the exact pinned archive when it is not already cached;
4. verifies SHA-256 before extraction;
5. extracts to an isolated temporary directory;
6. requires every declared payload to exist exactly once;
7. stages only validated `.kext` bundles under `build/efi/EFI/OC/Kexts`;
8. records archive and payload hashes in `build/opencore/kext-assets.json`;
9. emits license notices for artifacts marked `requiresLicenseNotice`;
10. rolls back the previous staged state if the transaction fails.

Existing staged payloads are preserved by default. Use `-Force` only when intentionally replacing them:

```powershell
.\scripts\acquire-kext-assets.ps1 -Force
```

This stage **does not modify `config.plist` or `Kernel -> Add`**. That separation is intentional: asset acquisition and verification must succeed before configuration composition begins.

## Hardware agnosticism

Unknown hardware is valid input. It receives only the generic core requirements plus explicitly matched profiles; it is never mapped to an unrelated machine. The acquisition script contains no hardware IDs, model names, GPU-specific branches, or assumptions about the current host.
