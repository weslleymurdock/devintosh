# `validate-opencore.ps1`

Validates the generated `config.plist` with `ocvalidate` from the same pinned OpenCore release used by the build stage.

## Usage

```powershell
.\scripts\validate-opencore.ps1
```

## Role

This is the structural validation gate after OpenCore configuration and kext composition. The validator version is pinned to prevent a newer schema from accepting or rejecting settings differently from the generated candidate.

A successful validation means the plist conforms to the pinned OpenCore schema. It does not imply that every hardware-specific feature has been runtime-tested; `NeedsValidation` remains a separate pipeline state.
