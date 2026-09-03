# Audio fallback strategy

The audio pipeline is hardware-agnostic and treats native codec configuration as the preferred path, while allowing a validated alternative transport when native macOS codec support cannot be established safely.

## Preferred path

The resolver first identifies audio controllers/codecs from the live hardware inventory and evaluates declarative profiles under `config/hardware/audio/`.

A known codec does **not** imply a valid macOS `layout-id`. The resolver must therefore keep the audio capability in `NeedsValidation` until native macOS evidence or an explicitly validated profile establishes the correct configuration.

The following must never be inferred automatically from a Windows codec/device name alone:

- `layout-id`;
- `alcid` boot arguments;
- `DeviceProperties` audio injection;
- codec-specific ACPI patches;
- speaker, microphone, headphone, or line-out routing.

## Validated alternative transport

If the native audio path cannot be validated, the project may use an alternative audio transport as a fallback, provided that the transport is independently supported by macOS and its complete configuration is represented by a declarative, validated profile.

The fallback is a **capability-level strategy**, not a hardware-specific exception. A profile may declare that a validated alternative transport is available when its prerequisites are satisfied.

A fallback profile must explicitly declare:

1. the transport or capability it provides;
2. the macOS support mechanism required by that transport;
3. the prerequisites that must be observed before activation;
4. any required kexts, drivers, services, or OpenCore entries through the existing catalogs/profile system;
5. validation evidence required before mutation;
6. limitations and expected functionality.

The resolver must not select a fallback merely because the native codec is unresolved. It may report the fallback as an available strategy, but activation requires an explicit validated profile or validation result.

## Validation order

The intended decision flow is:

```text
Detected audio hardware
        |
        v
Native codec profile
        |
        +---- validated ----> native audio configuration
        |
        +---- not validated
                    |
                    v
             Alternative transport
                    |
                    +---- validated ----> fallback audio configuration
                    |
                    +---- not validated -> NeedsValidation
```

This keeps the generic pipeline reusable across machines. The repository does not assume that a particular physical audio device, codec, motherboard, or connection method will be present on every installation.

## Safety rules

- Never map an unknown audio device to a known codec profile.
- Never generate a `layout-id` by guessing from a codec identifier.
- Never enable an alternative transport solely because it happens to work on the development machine.
- Never persist machine-specific pairing information, device addresses, serials, or other private identifiers in a hardware profile.
- Keep transport-specific binaries in the normal pinned kext/catalog pipeline.
- Require `ocvalidate` after any OpenCore mutation.
- Keep fallback activation separate from capability detection and resolution.
- Preserve `NeedsProfile` and `NeedsValidation` states rather than silently degrading into an unverified configuration.

## Reusability

A future validated profile can provide either the native codec configuration or an alternative transport without changing `resolve-audio.ps1`. The PowerShell resolver should remain generic; hardware and transport knowledge belongs in declarative profiles and catalogs.
