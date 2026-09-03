# `build-opencore.ps1`

Stages the pinned OpenCore release into the generated EFI workspace.

## Usage

```powershell
.\scripts\build-opencore.ps1
```

## Role

The script downloads the release declared in the version configuration, verifies its SHA-256, and stages the required `BOOTx64.efi` and `OC` tree.

The OpenCore version is pinned so generation and validation use the same schema. Binaries are generated under `build/` and are not committed.

## Design

No hardware identity is embedded in this stage. Hardware-specific behavior is deferred to declarative profiles.
