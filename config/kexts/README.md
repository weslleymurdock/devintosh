# Kext catalog

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

Binary archives are **not** committed to the repository. A later asset stage may download them, verify the recorded SHA-256, extract only the declared payloads, and place them under the generated EFI tree.

## Requirements

`core.json` declares the generic kext baseline. Hardware profiles may add entries through their `kexts` array.

A profile must not put a hardware-specific `if`/`switch` in PowerShell. Kext selection belongs in declarative profile data.

A `validation-required` hardware profile may still declare a kext. The resolver reports the kext and its validation state instead of silently treating the profile as fully validated.

## Resolution

Run:

```powershell
.\scripts\resolve-kexts.ps1
```

The result is written to `build/opencore/kext-resolution.json`.

This stage only resolves metadata. It does not download, install, copy, enable, or modify `config.plist`.

Unknown hardware is valid input. It receives the generic core requirements plus any explicitly matched profiles; it is never mapped to an unrelated hardware profile.
