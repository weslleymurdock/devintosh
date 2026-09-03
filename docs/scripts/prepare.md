# `prepare.ps1`

Performs non-destructive host preparation and selects a safe target resource for the installation workflow.

## Usage

```powershell
.\scripts\prepare.ps1
```

Optional target selection:

```powershell
.\scripts\prepare.ps1 -TargetDiskNumber <number>
```

Use `-Force` only when the script explicitly requires it for an operation that is already represented as safe by the workflow.

## Role

The stage checks administrator privileges, hardware inventory, UEFI/Secure Boot state, Windows capabilities, and storage candidates. It records the detected hardware manifest and creates the build workspace.

It does not format disks, create macOS partitions, install OpenCore, or change firmware settings.

## Safety

Boot/system disks are rejected as automatic targets. The stage supports rollback for its transactional state.
