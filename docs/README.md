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
    -> acquire-opencore-drivers.ps1
    -> resolve-gpu.ps1
    -> apply-opencore-profiles.ps1
    -> resolve-smbios.ps1
    -> bootstrap-smbios.ps1
    -> configure-first-boot.ps1
    -> resolve-acpi.ps1
    -> resolve-usb.ps1
    -> resolve-network.ps1
    -> resolve-audio.ps1
    -> resolve-kexts.ps1
    -> acquire-kext-assets.ps1
    -> compose-opencore-kexts.ps1
    -> validate-opencore.ps1
    -> readiness.ps1
    -> prepare-boot-disk.ps1
    -> first native macOS boot/install
    -> return to Windows
    -> validate-clover.ps1
    -> scripts/macos/collect-validation.sh
    -> runtime tests
    -> finalize-validation.sh
    -> scripts/import-macos-validation.ps1
    -> readiness.ps1
```

`resolve-gpu.ps1` is report-only. It identifies physical GPU capability profiles and compatibility requirements but never invents GPU spoofing, DeviceProperties, framebuffer or connector configuration.

`resolve-acpi.ps1` is currently report-only. It must be followed by native macOS ACPI validation before any future ACPI mutation stage is allowed to add, delete or patch tables.

`resolve-usb.ps1` is currently report-only. It must be followed by native macOS USB topology/port validation before any future USB mapping or topology mutation stage is allowed to change `config.plist`.

`resolve-network.ps1` is currently report-only. It resolves network controller capability profiles and validation requirements but does not acquire kexts or mutate `config.plist`.

`resolve-audio.ps1` is currently report-only. It resolves native audio capability profiles and validation/fallback requirements but does not select layout IDs, activate alternative transports, acquire kexts or mutate `config.plist`.

`resolve-smbios.ps1` resolves eligible SMBIOS product candidates but deliberately does not create identity data. `bootstrap-smbios.ps1` is the first-boot bridge: when exactly one SMBIOS candidate is eligible, it generates a synthetic, ephemeral local identity and applies it only to generated `build` output. The generated serial, MLB, UUID and ROM are never written to profiles or source control and are intentionally unsuitable as a long-term Apple identity. A separately validated SMBIOS identity remains required before long-term use of Apple services.

`acquire-opencore-drivers.ps1` stages the pinned `HfsPlus.efi` driver from Acidanthera's `OcBinaryData` repository after the OpenCore tree exists. The binary is SHA-256 verified and remains a build artifact; it is never committed to source control.

`configure-first-boot.ps1` applies first-boot-only security defaults after SMBIOS bootstrap. In particular, `Misc/Security/SecureBootModel` is set to `Disabled` until native validation establishes a suitable Secure Boot model. It does not generate or persist Apple SMBIOS identities.

`readiness.ps1` is the conservative pre-boot gate. It consumes the generated stage reports and final `ocvalidate` result. When native macOS validation evidence exists, explicitly validated GPU, SMBIOS, ACPI, USB, network, audio and kext runtime capabilities are reflected in the effective readiness state. It never mutates the configuration.

`prepare-boot-disk.ps1` is the destructive final Windows preparation stage. It accepts a safe non-system physical disk, creates GPT plus FAT32 EFI and Recovery staging partitions, leaves the remaining space unallocated for APFS creation by macOS Setup, stages OpenCore as the primary UEFI loader, and stages a pinned Clover fallback selector without modifying Windows BCD.

`validate-clover.ps1` is a post-install Windows-side verification stage. After macOS has been installed and the machine has returned to Windows, it uses DiskPart to inspect the prepared disk, mounts the EFI System Partition temporarily, validates Clover's EFI executable and `config.plist`, verifies the Clover custom entry to `\\EFI\\OC\\OpenCore.efi`, and verifies that OpenCore is present. Its `Valid` result means the Windows-visible Clover-to-OpenCore chain is structurally complete; it does not claim macOS hardware compatibility.

Native macOS validation is split into a read-only collector, an explicit runtime-test finalizer, and a Windows importer. The collector gathers runtime evidence and creates a SHA-256 manifest; the finalizer records only tests explicitly confirmed by the operator and regenerates the manifest; the importer verifies the bundle and stores the evidence transactionally.

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
| `acquire-opencore-drivers.ps1` | Acquire and verify OpenCore firmware drivers required by the generated configuration | [`scripts/acquire-opencore-drivers.md`](scripts/acquire-opencore-drivers.md) |
| `resolve-gpu.ps1` | Resolve GPU capability and validation requirements without mutating OpenCore | [`scripts/resolve-gpu.md`](scripts/resolve-gpu.md) |
| `apply-opencore-profiles.ps1` | Apply safe declarative OpenCore fragments | [`scripts/apply-opencore-profiles.md`](scripts/apply-opencore-profiles.md) |
| `resolve-smbios.ps1` | Resolve SMBIOS capability and candidates without generating identity data | [`scripts/resolve-smbios.md`](scripts/resolve-smbios.md) |
| `bootstrap-smbios.ps1` | Generate a local ephemeral SMBIOS identity required for first-boot OpenCore initialization | [`scripts/bootstrap-smbios.md`](scripts/bootstrap-smbios.md) |
| `configure-first-boot.ps1` | Apply first-boot SecureBootModel policy without persisting Apple identity data | No separate document yet |
| `resolve-kexts.ps1` | Resolve catalogued kexts and dependencies | [`scripts/resolve-kexts.md`](scripts/resolve-kexts.md) |
| `acquire-kext-assets.ps1` | Download, verify, extract, and stage kext bundles | [`scripts/acquire-kext-assets.md`](scripts/acquire-kext-assets.md) |
| `compose-opencore-kexts.ps1` | Compose `Kernel -> Add` from verified bundle metadata | [`scripts/compose-opencore-kexts.md`](scripts/compose-opencore-kexts.md) |
| `resolve-acpi.ps1` | Resolve ACPI capability and validation requirements without generating patches | [`scripts/resolve-acpi.md`](scripts/resolve-acpi.md) |
| `resolve-usb.ps1` | Resolve USB controller capability and validation requirements without generating a port map | [`scripts/resolve-usb.md`](scripts/resolve-usb.md) |
| `resolve-network.ps1` | Resolve network controller capability and validation requirements without mutating OpenCore | [`scripts/resolve-network.md`](scripts/resolve-network.md) |
| `resolve-audio.ps1` | Resolve audio capability and native/fallback validation requirements without mutating OpenCore | [`scripts/resolve-audio.md`](scripts/resolve-audio.md) |
| `apply-smbios.ps1` | Apply an explicitly validated SMBIOS identity transactionally | [`scripts/apply-smbios.md`](scripts/apply-smbios.md) |
| `validate-opencore.ps1` | Validate the generated plist with the pinned `ocvalidate` plus first-boot semantic prerequisites | [`scripts/validate-opencore.md`](scripts/validate-opencore.md) |
| `readiness.ps1` | Consolidate generated state into a conservative pre-boot readiness decision | [`scripts/readiness.md`](scripts/readiness.md) |
| `prepare-boot-disk.ps1` | Create GPT/EFI/Recovery staging and a boot-ready OpenCore+Clover disk | [`scripts/prepare-boot-disk.md`](scripts/prepare-boot-disk.md) |
| `validate-clover.ps1` | Validate the installed Clover EFI chain and config.plist from Windows | [`scripts/validate-clover.md`](scripts/validate-clover.md) |
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
- `build/opencore/smbios-bootstrap-report.json`
- `build/opencore/smbios-application-report.json`
- `build/opencore/first-boot-config-report.json`
- `build/opencore/validation-report.json`
- `build/opencore/readiness-report.json`
- `build/opencore/clover-validation-report.json`
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
8. SMBIOS long-term unique identifiers must never be generated or persisted automatically by the generic resolver; the first-boot bootstrap is the explicit exception and is local-only, synthetic, and never source-controlled.
9. ACPI tables and patches must require explicit validated macOS evidence before mutation.
10. USB port maps and topology changes must require explicit validated macOS evidence before mutation.
11. Network kext acquisition and `Kernel -> Add` composition must remain separate from hardware capability resolution.
12. Audio layout IDs, routing, and alternative transports must require explicit validated macOS evidence before activation.
13. GPU compatibility, spoofing, DeviceProperties and framebuffer/connector changes must require explicit validated macOS evidence before activation.
14. The readiness gate is conservative: missing/malformed inputs block evaluation; unresolved capabilities never become `Ready` by inference.
15. Native macOS validation evidence must be read-only, SHA-256 verified, privacy-redacted, and imported transactionally.
16. Device presence alone is never considered proof of runtime compatibility; explicit validation markers are required.
17. Windows disk preparation uses GPT for modern Intel UEFI systems; Apple Partition Map is not used.
18. The boot-disk preparation stage never modifies Windows BCD and never fabricates an APFS filesystem from Windows.
19. Clover validation is Windows-side and structural; it must never be represented as proof of macOS hardware compatibility.
20. OpenCore vault enforcement must remain disabled unless the pipeline also generates and verifies the corresponding vault artifacts.
21. First-boot OpenCore semantic prerequisites must be validated before destructive disk preparation; a missing HfsPlus.efi or zero/empty SMBIOS identity must never be discovered for the first time after reboot.
