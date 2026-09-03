# `apply-opencore-profiles-fixed.ps1`

Internal implementation used by `apply-opencore-profiles.ps1`.

It contains the transactional orchestration for loading matched profiles, detecting fragment conflicts, applying safe declarative values, creating a timestamp-safe backup, and emitting the application report.

Users should invoke the public compatibility entry point instead:

```powershell
.\scripts\apply-opencore-profiles.ps1 -Force
```

The implementation contains no hardware-specific identifiers or decision branches.
