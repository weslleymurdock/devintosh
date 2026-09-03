# `configure-opencore-hardware.ps1`

Builds a normalized hardware inventory from the live Windows host.

## Usage

```powershell
.\scripts\configure-opencore-hardware.ps1
```

## Role

The stage collects platform, BIOS, CPU, physical GPU, audio, network, USB, ACPI, and relevant PCI/PnP identities. It writes `build/opencore/hardware-detected.json` for subsequent data-driven resolution.

## Design

This is an observation-only stage. It does not decide which macOS settings should be applied and does not fabricate SMBIOS identifiers, USB maps, ACPI patches, audio layout IDs, or kext versions.

A new hardware family can therefore be supported by adding declarative profile data rather than editing this script.
