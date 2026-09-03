# SMBIOS compatibility matrix

## Purpose

This document defines the current SMBIOS decision matrix used by Devintosh for Intel desktop systems. It is intentionally hardware-agnostic: the matrix uses CPU generation and GPU topology, not a particular motherboard, serial number, UUID, or machine.

The resolver is **report-only**. It does not generate or persist `SystemSerialNumber`, `MLB`, `SystemUUID`, or `ROM`, and it does not apply a Mac model automatically.

## Current macOS target

The current project target is macOS Sequoia 15. Older SMBIOS generations that are no longer current macOS targets are not automatically selected merely because their CPU generation is historically compatible.

## Decision matrix

| Host class | GPU topology | Candidate | Confidence | Automatic application |
| --- | --- | --- | --- | --- |
| Intel desktop 8th/9th Gen | Intel integrated GPU present | `iMac19,1` | Documented | No; validation required |
| Intel desktop 10th Gen, up to 8 cores | Intel integrated GPU present | `iMac20,1` | Documented | No; validation required |
| Intel desktop 11th-14th Gen | Discrete/physical GPU present | `MacPro7,1` | Community-validated + documented selection rule | No; validation required |
| Intel desktop outside these classes | Any | No automatic candidate | — | Remain `NeedsValidation` |
| Any Intel desktop with an ambiguous/undetected GPU topology | Unknown | No automatic candidate | — | Remain `NeedsValidation` |

### Why GPU topology is part of the matrix

Dortania explicitly warns that SMBIOS selection is not just a CPU match. GPU topology affects power management, display routing and graphics behavior. In particular, iMac SMBIOS models assume an iGPU; for CPUs without an iGPU, Dortania directs users toward iMac Pro or Mac Pro SMBIOS families. It also identifies `iMacPro1,1` and `MacPro7,1` as the SMBIOS families capable of letting a supported dGPU handle the workload normally assigned to an iGPU. citeturn5search0

Therefore the resolver may use the **presence of a physical GPU** as a generic eligibility condition without embedding a specific GPU or motherboard into the SMBIOS profile.

## Evidence-backed candidates

### `iMac19,1`

Dortania's Coffee Lake desktop guide selects `iMac19,1` for Coffee Lake and describes it as the Mojave-and-newer choice, while `iMac18,3` is retained for older High Sierra configurations. The broader SMBIOS table lists `iMac19,1` as Coffee Lake desktop hardware and currently supported. citeturn4search1turn5search0

The Devintosh rule therefore limits this candidate to 8th/9th Gen Intel desktop CPUs **with a detected Intel integrated GPU**. The resolver still reports `NeedsValidation`; it does not infer that a given motherboard's complete macOS configuration is correct.

### `iMac20,1`

Dortania's Comet Lake desktop guide recommends `iMac20,1` for i7-10700K and lower, while `iMac20,2` is reserved for the higher-core i9 class. The broader SMBIOS table lists `iMac20,1` as Comet Lake desktop hardware and currently supported. citeturn4search0turn5search0

The Devintosh rule therefore limits `iMac20,1` to 10th Gen Intel desktop CPUs with at most eight cores and a detected Intel integrated GPU.

### `MacPro7,1`

Dortania states that `MacPro7,1` and `iMacPro1,1` are the two SMBIOS choices that can allow a dGPU to handle all workload, and specifically warns that iGPU-less CPUs require special care because iMac SMBIOS models assume an iGPU. It also states that this path requires a Polaris, Vega or Navi GPU to work properly. citeturn5search0

For modern Intel desktop systems, independent Alder Lake guidance commonly selects `MacPro7,1`; the documented Alder Lake guide explicitly describes it as the majority/recommended choice and notes that iMac SMBIOS choices impose an iGPU assumption. citeturn3search4

Devintosh consequently treats `MacPro7,1` as an **evidence-backed candidate**, not as a universal assertion. The candidate requires a detected physical GPU, while exact GPU compatibility remains a separate graphics-resolution concern. This distinction is important: the SMBIOS matrix must not silently claim that every dGPU is supported.

## Deliberate exclusions

- `iMacPro1,1` is not currently an automatic candidate. Although it is valid for iGPU-less/dGPU configurations, its native CPU/GPU class is Skylake-W/Vega and there is less reason to prefer it over `MacPro7,1` for the current modern Intel desktop target. Keeping it validation-only avoids turning a valid alternative into an arbitrary default. citeturn5search0
- `iMac20,2` is not selected generically; Dortania describes it as the special higher-core Comet Lake option and specifically notes that it is intended for Apple's custom i9-10910 class. citeturn5search0
- `Macmini8,1` is not used as a generic desktop fallback. Dortania recommends avoiding Mac mini SMBIOS on ordinary desktop systems and primarily associates it with mobile hardware such as Intel NUCs. citeturn5search0
- Older SMBIOS generations are not automatically selected for Sequoia simply because their CPU generation is known. For example, `iMac17,1` is listed as dropped in Ventura by the current Dortania desktop Skylake guide. citeturn2search3
- No candidate is generated solely because a CPU name resembles a known Mac CPU. Candidate eligibility also considers the generic GPU topology requirement.

## Hardware-agnostic behavior

The matrix must preserve these invariants:

1. No motherboard model is embedded in the decision rule.
2. No serial number, MLB, UUID or ROM is embedded in a profile.
3. A missing GPU does not cause the installer to fail. It simply means candidates that require a physical GPU are ineligible, so the resolver remains `NeedsValidation` until a validated no-GPU strategy exists.
4. A detected GPU does not prove graphics support. Exact GPU support is resolved independently.
5. An unknown CPU generation does not get mapped to the nearest known generation.
6. `NeedsValidation` is a valid terminal state for the resolver and is preferable to an unsafe guess.

## Relationship with `apply-smbios.ps1`

`resolve-smbios.ps1` produces candidate evidence only. `apply-smbios.ps1` remains a separate transactional stage and must receive an explicitly validated selection containing the complete identity data required by OpenCore.

OpenCore itself validates that `PlatformInfo -> Generic -> SystemProductName` is a real Mac model and accepts only a valid UUID (or the documented empty/`OEM` forms). citeturn0search0turn0search1

Unique SMBIOS values are therefore intentionally outside this matrix and outside source control.

## Primary references

- OpenCore Install Guide — Choosing the right SMBIOS: https://dortania.github.io/OpenCore-Install-Guide/extras/smbios-support.html
- OpenCore Install Guide — Coffee Lake: https://dortania.github.io/OpenCore-Install-Guide/config.plist/coffee-lake.html
- OpenCore Install Guide — Comet Lake: https://dortania.github.io/OpenCore-Install-Guide/config.plist/comet-lake.html
- OpenCore Install Guide — Skylake: https://dortania.github.io/OpenCore-Install-Guide/config.plist/skylake.html
- OpenCore Visual Beginners Guide — Alder Lake: https://chriswayg.gitbook.io/opencore-visual-beginners-guide/advanced-topics/using-alder-lake
- OpenCore `ocvalidate`: https://github.com/acidanthera/OpenCorePkg/blob/master/Utilities/ocvalidate/README.md
