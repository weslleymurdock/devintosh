# Devintosh documentation

This directory is the documentation entry point for the project. The root `README.md` intentionally stays minimal and points here.

## Pipeline

```text
validate.ps1
    -> prepare.ps1
    -> download-recovery.ps1
    -> build-opencore.ps1
    -> configure-opencore-hardware.ps1
    -> configure-opencore.ps1
    -> apply-opencore-profiles.ps1
    -> resolve-kexts.ps1
    -> acquire-kext-assets.ps1
    -> compose-opencore-kexts.ps1
    -> validate-opencore.ps1
```

The pipeline is **hardware-agnostic and data-driven**. Hardware-specific decisions belong in declarative profiles and catalogs, not in PowerShell branches. Unknown hardware must remain representable as `NeedsProfile`; known hardware that requires additional validation must remain `NeedsValidation`.

## Scripts

| Script | Purpose | Documentation |
|---|---|---|
| `validate.ps1` | Host compatibility baseline | [`scripts/validate.md`](scripts/validate.md) |
| `prepare.ps1` | Non-destructive host preparation and target selection | [`scripts/prepare.md`](scripts/prepare.md) |
| `download-recovery.ps1` | Download and verify macOS Recovery assets | [`scripts/download-recovery.md`](scripts/download-recovery.md) |
| `build-opencore.ps1` | Stage the pinned OpenCore release | [`scripts/build-opencore.md`](scripts/build-opencore.md) |
| `configure-opencore-hardware.ps1` | Detect live Windows hardware facts | [`scripts/configure-opencore-hardware.md`](scripts/configure-opencore-hardware.md) |
| `configure-opencore.ps1` | Resolve hardware capabilities and generate a conservative candidate | [`scripts/configure-opencore.md`](scripts/configure-opencore.md) |
| `apply-opencore-profiles.ps1` | Apply safe declarative OpenCore fragments | [`scripts/apply-opencore-profiles.md`](scripts/apply-opencore-profiles.md) |
| `resolve-kexts.ps1` | Resolve catalogued kexts and dependencies | [`scripts/resolve-kexts.md`](scripts/resolve-kexts.md) |
| `acquire-kext-assets.ps1` | Download, verify, extract, and stage kext bundles | [`scripts/acquire-kext-assets.md`](scripts/acquire-kext-assets.md) |
| `compose-opencore-kexts.ps1` | Compose `Kernel -> Add` from verified bundle metadata | [`scripts/compose-opencore-kexts.md`](scripts/compose-opencore-kexts.md) |
| `validate-opencore.ps1` | Validate the generated plist with the pinned `ocvalidate` | [`scripts/validate-opencore.md`](scripts/validate-opencore.md) |
| `apply-opencore-profiles-fixed.ps1` | Internal implementation used by the compatibility wrapper | [`scripts/apply-opencore-profiles-fixed.md`](scripts/apply-opencore-profiles-fixed.md) |

## Shared libraries

| Library | Documentation |
|---|---|
| `scripts/lib/common.ps1` | [`scripts/lib-common.md`](scripts/lib-common.md) |
| `scripts/lib/console.ps1` | [`scripts/lib-console.md`](scripts/lib-console.md) |
| `scripts/lib/progress.ps1` | [`scripts/lib-progress.md`](scripts/lib-progress.md) |
| `scripts/lib/logging.ps1` | [`scripts/lib-logging.md`](scripts/lib-logging.md) |
| `scripts/lib/rollback.ps1` | [`scripts/lib-rollback.md`](scripts/lib-rollback.md) |
| `scripts/lib/hardware.ps1` | [`scripts/lib-hardware.md`](scripts/lib-hardware.md) |
| `scripts/lib/storage.ps1` | [`scripts/lib-storage.md`](scripts/lib-storage.md) |
| `scripts/lib/opencore-profile-engine.ps1` | [`scripts/lib-opencore-profile-engine.md`](scripts/lib-opencore-profile-engine.md) |

## Generated state

Build output is intentionally kept outside source control. Important generated manifests include:

- `build/opencore/hardware-detected.json`
- `build/opencore/hardware-resolution.json`
- `build/opencore/kext-resolution.json`
- `build/opencore/kext-assets.json`
- `build/opencore/kext-composition-report.json`
- `build/efi/EFI/OC/config.plist`

## Design rules

1. Never hardcode the developer's hardware into a generic script.
2. Never spoof or guess an unknown device into a known profile.
3. Prefer `NeedsProfile` or `NeedsValidation` over unsafe automation.
4. Keep downloads pinned by version and SHA-256.
5. Do not commit generated EFI, Recovery images, DMGs, ISOs, logs, or real SMBIOS identifiers.
6. Use automatic rollback for mutating stages.
7. Validate the final OpenCore configuration with the same pinned release used to generate it.
