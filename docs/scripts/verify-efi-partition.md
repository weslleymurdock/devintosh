# verify-efi-partition.ps1

## Purpose

`verify-efi-partition.ps1` is the final physical-boot-layout gate. It validates the EFI System Partition that actually exists on the target disk after `prepare-boot-disk.ps1` has staged OpenCore.

The validator is non-destructive: it does not partition, format, copy, delete, or modify UEFI boot variables. If the EFI partition does not already have a drive letter, it temporarily assigns one for inspection and removes it afterward.

## Required layout

The target disk must satisfy all of the following:

- GPT partition style.
- Exactly one EFI System Partition (ESP).
- ESP GPT type `C12A7328-F81F-11D2-BA4B-00A0C93EC93B`.
- ESP formatted as FAT32.
- ESP size of at least 256 MiB.
- `EFI\BOOT\BOOTX64.EFI` exists.
- `EFI\OC\OpenCore.efi` exists.
- `EFI\OC\config.plist` exists.
- `BOOTX64.EFI` and `OpenCore.efi` are valid x86-64 PE EFI binaries.

The `EFI\BOOT\BOOTX64.EFI` path is important because it is the UEFI fallback boot path used when firmware needs to boot an EFI application without relying on a pre-existing boot entry. OpenCore documents `BOOTx64.efi` as the firmware bootstrap loader and `EFI\OC\OpenCore.efi` as the main OpenCore application.

## Standalone inspection

Run from an elevated Windows PowerShell 5.1 session:

```powershell
.\scripts\verify-efi-partition.ps1 -TargetDiskNumber 1
```

Replace `1` with the physical disk number to inspect. This mode is intended for validating an existing disk before a clean retry. A failure is useful: the exception identifies the first structural requirement that is not satisfied.

Without `-TargetDiskNumber`, the script scans physical disks and succeeds only when exactly one disk contains the complete Devintosh EFI layout:

```powershell
.\scripts\verify-efi-partition.ps1
```

If no disk has the complete layout, specify the disk number explicitly so the validator can report the exact structural failure.

## Pipeline position

The stage runs immediately after `prepare-boot-disk.ps1`:

1. All non-destructive artifact/configuration stages.
2. `prepare-boot-disk.ps1` — the only destructive stage; requires explicit confirmation.
3. `verify-efi-partition.ps1` — validates the actual on-disk EFI structure.
4. Pipeline reports success only if the physical EFI gate passes.

This prevents a run from being reported as successful when the generated artifacts were correct in the repository but the physical ESP ended up with an invalid UEFI entrypoint/layout.
