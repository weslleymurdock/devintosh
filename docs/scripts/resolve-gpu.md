# resolve-gpu.ps1

## Purpose

Resolves physical GPU capability profiles from the live Windows hardware inventory without modifying `config.plist`.

The stage is deliberately report-only. GPU compatibility on macOS cannot be established safely from a Windows PCI identity alone. In particular, a known device ID does not authorize automatic spoofing, `DeviceProperties`, framebuffer patches, connector/BusID changes, or ACPI changes.

## Input

- `build/opencore/hardware-detected.json`
- `config/hardware/gpu/**/*.json`

Profiles are declarative. PowerShell contains no motherboard, GPU model, Device ID, or spoof-specific branch.

## Matching

Profiles may match physical GPUs by:

- `gpuVendorId`
- `gpuDeviceIds`
- `gpuSubsystemIds`
- `anyOf` alternatives containing the same identity fields

A GPU is considered physical only when both `VendorId` and `DeviceId` are four-digit PCI identifiers. Virtual/unidentified display adapters are retained in the report but are never matched as physical GPUs.

## Resolution states

- `Resolved`: a profile exists and declares no additional validation requirement.
- `NeedsValidation`: a profile exists but macOS-side compatibility, spoofing, or other validation is required.
- `NeedsProfile`: a physical GPU exists without a matching capability profile, or no usable physical GPU identity was detected.

Unknown hardware is therefore represented rather than rejected or mapped to another GPU.

## Safety policy

The resolver never generates or applies:

- GPU spoof identities
- `DeviceProperties`
- framebuffer patches
- connector/BusID patches
- GPU ACPI patches
- compatibility claims derived from Windows driver versions

WhateverGreen can be declared by a profile and resolved by the independent kext pipeline, but the GPU stage does not download, copy, enable, or compose kexts.

WhateverGreen's own Radeon FAQ states that AMD 5xxx-and-newer GPUs commonly need WhateverGreen, while also noting that not every GPU/configuration can be tested. Therefore the profile can express a WEG requirement without converting that fact into an unconditional compatibility claim. citeturn0search14

## Current Lexa profile

The existing Lexa RX 550 profile remains validation-gated. It identifies the device family and requests WhateverGreen through the normal kext catalog, but does not invent a spoof identity. This is intentional because exact macOS compatibility and any required spoof must be established independently.

## Output

`build/opencore/gpu-resolution.json`

The report contains:

- physical GPU inventory
- virtual/unidentified display adapters
- matched profiles
- declarative strategies
- unmatched physical GPUs
- warnings and unresolved capabilities
- artifacts intentionally not generated

## Transaction behavior

The generated report is written transactionally. With `-Force`, an existing report is backed up under `build/backups/gpu/` before replacement and is registered with the shared rollback mechanism.

No EFI/configuration mutation occurs in this stage, so later profile-application stages remain responsible for explicit, validated GPU configuration.

## Validation evidence

Dortania's hardware guidance directs users to the GPU Buyers Guide to establish GPU support before installation. citeturn0search0

Dortania's OpenCore configuration examples also demonstrate that GPU/iGPU `DeviceProperties` are platform-specific and should be added only when the corresponding hardware path and configuration are known. citeturn0search1turn0search3
