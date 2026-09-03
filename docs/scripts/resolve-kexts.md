# `resolve-kexts.ps1`

Creates the deterministic kext plan from the generic core manifest, matched hardware profiles, and the pinned kext catalog.

## Usage

```powershell
.\scripts\resolve-kexts.ps1
```

## Role

The resolver validates release metadata, SHA-256 declarations, licenses, payloads, and dependencies, then performs dependency ordering. It does not download or modify the EFI.

The result is `build/opencore/kext-resolution.json`.

`NeedsValidation` is preserved when a matched profile requires validation; it is not converted into a success state merely because the artifact exists in the catalog.
