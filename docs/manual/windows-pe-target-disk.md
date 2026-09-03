# Preparing a Windows boot/system disk from Windows PE

## Why the Devintosh safety check cannot be disabled

`prepare-boot-disk.ps1` intentionally refuses a disk that Windows reports as the active boot/system disk.

This is not a normal confirmation problem. If the currently running Windows installation depends on that disk, executing `diskpart clean` against it would destroy the running operating system, its boot files, or both. Microsoft documents that `diskpart clean` removes the partition/volume formatting from the selected disk. There is no generic rollback for this operation.

Therefore Devintosh does **not** provide an `-IgnoreSafety`, `-DisableSafety`, or equivalent switch. `-Force` only acknowledges that a non-protected target will be destroyed, and the interactive confirmation remains mandatory.

## When this procedure is required

Use this procedure when the desired Devintosh target is the same physical disk currently hosting Windows Boot Manager/Windows, or when Windows marks the target disk as a boot/system disk.

First verify the situation from an elevated PowerShell:

```powershell
Get-Disk | Format-Table Number,FriendlyName,PartitionStyle,OperationalStatus,IsBoot,IsSystem,Size -AutoSize
```

If the intended target has `IsBoot=True` or `IsSystem=True`, do not try to disable the protection from the live Windows installation.

## Recommended procedure

Boot the machine from Windows installation media or another Windows PE environment. Microsoft documents using Windows Setup/WinPE and `Shift+F10` to obtain a command prompt for storage operations.

At the Windows Setup screen:

1. Boot from a Windows 11 installation USB.
2. Choose the language/keyboard options if prompted.
3. At the first Windows Setup screen, press `Shift+F10`.
4. A command prompt opens in Windows PE.
5. Verify the disks:

```text
diskpart
list disk
list vol
exit
```

Do **not** use `SELECT DISK=SYSTEM` to identify the target in a UEFI environment. Microsoft specifically warns that this selection mode is inappropriate for UEFI systems with multiple disks.

## Running Devintosh from WinPE

The Devintosh repository must be available from a location that will survive the destruction of the target disk, such as:

- a second internal disk;
- a USB drive containing the repository;
- a network share, if networking is available in WinPE.

Change to the repository directory, for example:

```powershell
Set-Location D:\devintosh
```

The drive letter is only an example. WinPE assigns drive letters independently from the normal Windows installation, so identify the repository location with `Get-Volume` or `diskpart` first.

Then execute the normal interactive preparation command:

```powershell
.\scripts\prepare-boot-disk.ps1 -Force
```

The menu will enumerate disks that are safe to destroy in the current WinPE environment. Select the intended physical disk and confirm the exact token shown by the script, such as:

```text
ERASE-DISK-0
```

The script will then perform the destructive operation and create:

```text
GPT
├── EFI              512 MiB FAT32
│   ├── EFI/BOOT/BOOTX64.EFI
│   ├── EFI/OC/
│   └── EFI/CLOVER/
├── OCRECOVERY       2 GiB FAT32
│   └── com.apple.recovery.boot/
│       ├── BaseSystem.dmg
│       └── BaseSystem.chunklist
└── unallocated      remaining space for macOS/APFS
```

## Important distinction

There is no manual step to permanently disable the Devintosh safety check.

The manual step is to **change the execution environment** so the disk being erased is no longer the disk hosting the currently running Windows system.

This is substantially safer than adding a bypass switch to the script because a typo in a disk number while running the normal Windows installation could otherwise destroy the host operating system.

## If the target is a secondary NTFS data disk

If the target is merely an NTFS data disk and Windows is running from another physical disk, no WinPE boot is required. The normal Windows session can be used:

```powershell
.\scripts\prepare-boot-disk.ps1 -Force
```

Select the NTFS disk from the menu and confirm its destructive token.

The script will erase the selected disk, convert it to GPT, create the EFI and Recovery staging partitions, and leave the rest unallocated for macOS Setup.

## Do not manually run `clean` first

Do not run:

```text
diskpart
select disk N
clean
```

before invoking Devintosh. Let the script perform the complete partitioning operation after its own validation and confirmation. This keeps the generated manifest, drive-letter handling, EFI staging, Recovery staging, and final verification in one controlled operation.

## References

- Microsoft DiskPart `clean`: https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/clean
- Microsoft DiskPart scripts and examples: https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/diskpart-scripts-and-examples
- Microsoft guidance for selecting disks in UEFI environments: https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/configure-multiple-hard-drives?view=windows-11
