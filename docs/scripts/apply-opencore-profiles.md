# `apply-opencore-profiles.ps1`

Applies safe declarative OpenCore plist fragments supplied by matched hardware profiles.

## Usage

```powershell
.\scripts\apply-opencore-profiles.ps1 -Force
```

## Role

Profiles can declare typed plist fragments under `opencore.plist`. The generic fragment engine applies those values without containing hardware-specific PowerShell branches.

Profiles with `opencore.policy = validation-required` are skipped and remain represented in the reports.

Conflicting writes to the same plist path are rejected. Mutations are transactional and the previous candidate is restored if writing fails.

## Outputs

- `build/efi/EFI/OC/config.plist`
- `build/opencore/profile-application-report.json`
