# Devintosh documentation

This directory is the documentation entry point for the project. The root `README.md` intentionally stays minimal and points here.

## Architecture

The future single-call `main.ps1` orchestration and transaction model are documented in [`architecture-transactional-orchestration.md`](architecture-transactional-orchestration.md). The script itself is intentionally not implemented yet; stages continue to be validated manually first.

## Pipeline

```text
validate.ps1
    -> prepare.ps1
    -> download-recovery.ps1
    -> build-opencore.ps1
    -> configure-opencore-hardware.ps1
    -> configure-opencore.ps1
    -> resolve-gpu.ps1
    -> apply-opencore-profiles.ps1
    -> resolve-kexts.ps1
    -> acquire-kext-assets.ps1
    -> compose-opencore-kexts.ps1
    -> resolve-acpi.ps1
    -> resolve-usb.ps1
    -> resolve-network.ps1
    -> resolve-audio.ps1
    -> resolve-smbios.ps1
    -> apply-smbios.ps1
    -> validate-opencore.ps1
    -> readiness.ps1
    -> native macOS boot
    -> scripts/macos/collect-validation.sh
    -> scripts/import-macos-validation.ps1
    -> future validation application stage
    -> readiness.ps1
```

`resolve-gpu.ps1` is report-only. It identifies physical GPU capability profiles and compatibility requirements but never invents GPU spoofing, DeviceProperties, framebuffer or connector configuration.

`resolve-acpi.ps1` is currently report-only. It must be followed by native macOS ACPI validation before any future ACPI mutation stage is allowed to add, delete or patch tables.

`resolve-usb.ps1` is currently report-only. It must be followed by native macOS USB topology/port validation before any future USB mapping or topology mutation stage is allowed to change `config.plist`.

`resolve-network.ps1` is currently report-only. It resolves network controller capability profiles and validation requirements but does not acquire kexts or mutate `config.plist`.

`resolve-audio.ps1` is currently report-only. It resolves native audio capability profiles and validation/fallback requirements but does not select layout IDs, activate alternative transports, acquire kexts or mutate `config.plist`.

`readiness.ps1` is the conservative pre-boot gate. It consumes the generated stage reports and the final `ocvalidate` result, then reports `Ready`, `NeedsValidation`, `NeedsProfile` or `Blocked`. It never mutates the configuration.

Native macOS validation is split into a read-only collector and a Windows importer. The collector gathers runtime evidence and creates a SHA-256 manifest; the importer verifies the bundle and records explicit validation markers without guessing compatibility or mutating OpenCore.

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
| `resolve-gpu.ps1` | Resolve GPU capability and validation requirements without mutating OpenCore | [`scripts/resolve-gpu.md`](scripts/resolve-gpu.md) |
| `apply-opencore-profiles.ps1` | Apply safe declarative OpenCore fragments | [`scripts/apply-opencore-profiles.md`](scripts/apply-opencore-profiles.md) |
| `resolve-kexts.ps1` | Resolve catalogued kexts and dependencies | [`scripts/resolve-kexts.md`](scripts/resolve-kexts.md) |
| `acquire-kext-assets.ps1` | Download, verify, extract, and stage kext bundles | [`scripts/acquire-kext-assets.md`](scripts/acquire-kext-assets.md) |
| `compose-opencore-kexts.ps1` | Compose `Kernel -> Add` from verified bundle metadata | [`scripts/compose-opencore-kexts.md`](scripts/compose-opencore-kexts.md) |
| `resolve-acpi.ps1` | Resolve ACPI capability and validation requirements without generating patches | [`scripts/resolve-acpi.md`](scripts/resolve-acpi.md) |
| `resolve-usb.ps1` | Resolve USB controller capability and validation requirements without generating a port map | [`scripts/resolve-usb.md`](scripts/resolve-usb.md) |
| `resolve-network.ps1` | Resolve network controller capability and validation requirements without mutating OpenCore | [`scripts/resolve-network.md`](scripts/resolve-network.md) |
| `resolve-audio.ps1` | Resolve audio capability and native/fallback validation requirements without mutating OpenCore | [`scripts/resolve-audio.md`](scripts/resolve-audio.md) |
| `resolve-smbios.ps1` | Resolve SMBIOS capability and candidates without generating identity data | [`scripts/resolve-smbios.md`](scripts/resolve-smbios.md) |
| `apply-smbios.ps1` | Apply an explicitly validated SMBIOS identity transactionally | [`scripts/apply-smbios.md`](scripts/apply-smbios.md) |
| `validate-opencore.ps1` | Validate the generated plist with the pinned `ocvalidate` | [`scripts/validate-opencore.md`](scripts/validate-opencore.md) |
| `readiness.ps1` | Consolidate generated state into a conservative pre-boot readiness decision | [`scripts/readiness.md`](scripts/readiness.md) |
| `scripts/macos/collect-validation.sh` | Collect read-only native macOS runtime evidence | [`scripts/macos-validation.md`](scripts/macos-validation.md) |
| `import-macos-validation.ps1` | Verify and import native macOS validation evidence | [`scripts/macos-validation.md`](scripts/macos-validation.md) |
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
- `build/opencore/configuration-report.json`
- `build/opencore/gpu-resolution.json`
- `build/opencore/acpi-resolution.json`
- `build/opencore/usb-resolution.json`
- `build/opencore/network-resolution.json`
- `build/opencore/audio-resolution.json`
- `build/opencore/kext-resolution.json`
- `build/opencore/kext-assets.json`
- `build/opencore/kext-composition-report.json`
- `build/opencore/smbios-resolution.json`
- `build/opencore/smbios-application-report.json`
- `build/opencore/validation-report.json`
- `build/opencore/readiness-report.json`
- `build/opencore/macos-validation/`
- `build/opencore/macos-validation-report.json`
- `build/efi/EFI/OC/config.plist`

## Design rules

1. Never hardcode the developer's hardware into a generic script.
2. Never spoof or guess an unknown device into a known profile.
3. Prefer `NeedsProfile` or `NeedsValidation` over unsafe automation.
4. Keep downloads pinned by version and SHA-256.
5. Do not commit generated EFI, Recovery images, DMGs, ISOs, logs, or real SMBIOS identifiers.
6. Use automatic rollback for mutating stages and transactional writes for generated state.
7. Validate the final OpenCore configuration with the same pinned release used to generate it.
8. SMBIOS unique identifiers must never be generated or persisted automatically by the generic pipeline.
9. ACPI tables and patches must require explicit validated macOS evidence before mutation.
10. USB port maps and topology changes must require explicit validated macOS evidence before mutation.
11. Network kext acquisition and `Kernel -> Add` composition must remain separate from hardware capability resolution.
12. Audio layout IDs, routing, and alternative transports must require explicit validated macOS evidence before activation.
13. GPU compatibility, spoofing, DeviceProperties and framebuffer/connector changes must require explicit validated macOS evidence before activation.
14. The readiness gate is conservative: missing/malformed inputs block evaluation; unresolved capabilities never become `Ready` by inference.
15. Native macOS validation evidence must be read-only, SHA-256 verified, privacy-redacted, and imported transactionally.
16. Device presence alone is never considered proof of runtime compatibility; explicit validation markers are required.
