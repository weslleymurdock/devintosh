# 🍏 DEVINTOSH

Here are sources, scripts and other resources to validate a host machine against the requirements of macOS installations.
There are validation scripts, and a fully automated scripting setup for bare metal macOS installation.

## VERSIONS

Currently only Sequoia is implemented.

## HARDWARE-AGNOSTIC PIPELINE

The configuration pipeline is data-driven. Hardware is inspected at runtime and matched against declarative profiles under `config/hardware`. Unknown hardware is reported as `NeedsProfile` rather than being mapped to another machine or receiving guessed hardware-specific settings.

The current pipeline is:

```text
hardware detection
    -> profile resolution
    -> clean OpenCore candidate
    -> declarative safe fragments
    -> OpenCore 1.0.7 validation
    -> kext metadata resolution
```

Kext binaries are not committed to the repository. `config/kexts/catalog.json` pins release metadata, SHA-256, license, payloads, and dependencies. Hardware profiles declare additional kext requirements without adding hardware-specific PowerShell branches.

The kext resolution stage is intentionally metadata-only at this point:

```powershell
.\scripts\resolve-kexts.ps1
```

It writes `build/opencore/kext-resolution.json` and does not modify the generated EFI or `config.plist`.

## CONTRIBUTING

Contributions are more than welcome, please follow the steps below:

- 1. Open an issue for the contribution, bugfix, improvement or new feature.
- 2. Fork the repo
- 3. Implement.
- 4. Open a PR and link the issue
