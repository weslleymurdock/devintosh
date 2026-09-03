# `compose-opencore-kexts.ps1`

Composes OpenCore `Kernel -> Add` entries from verified staged kext bundles.

## Usage

```powershell
.\scripts\compose-opencore-kexts.ps1 -Force
```

## Hardware-agnostic behavior

The script does not contain a hardware table. It consumes `build/opencore/kext-assets.json`, follows its already-resolved dependency order, and inspects each `.kext/Contents/Info.plist` to obtain `CFBundleExecutable`.

It verifies that the declared executable actually exists inside the staged bundle. `BundlePath`, `ExecutablePath`, and `PlistPath` are therefore derived from the acquired asset rather than guessed from a hardware-specific rule.

## Validation policy

Kexts marked `requiresValidation` are emitted in `Kernel -> Add` with `Enabled = false`. This keeps the artifact available for a later validation step without silently activating an unvalidated hardware configuration.

## Outputs

- Updates `build/efi/EFI/OC/config.plist`.
- Writes `build/opencore/kext-composition-report.json`.
- Creates a rollback backup before replacing the candidate.

The next stage is `validate-opencore.ps1`.
