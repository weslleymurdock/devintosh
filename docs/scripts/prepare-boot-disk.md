# prepare-boot-disk.ps1

Prepares a genuinely empty physical disk for the first Devintosh boot test.

## Important partitioning clarification

For Intel UEFI hardware, the required partition scheme is **GUID Partition Table (GPT)**, not Apple's historical **Apple Partition Map (APM)**. APM is intended for older PowerPC-era Mac compatibility; GPT is the appropriate scheme for modern Intel UEFI systems.

Windows can create the GPT and FAT32 EFI System Partition directly with `diskpart`. It cannot natively create an APFS filesystem/container. The script therefore leaves the remainder of the disk unallocated so the macOS installer can create the APFS container itself.

## Layout

```text
Target disk
└── GPT
    ├── EFI        512 MiB FAT32 / EFI System Partition
    │   ├── EFI/BOOT/BOOTX64.EFI       <- OpenCore primary loader
    │   ├── EFI/OC/                    <- generated OpenCore tree
    │   └── EFI/CLOVER/                <- Clover fallback selector
    ├── OCRECOVERY 2 GiB FAT32
    │   └── com.apple.recovery.boot/
    │       ├── BaseSystem.dmg
    │       └── BaseSystem.chunklist
    └── unallocated                    <- APFS created later by macOS Setup
```

`OCRECOVERY` is intentionally **not** an Apple APFS Recovery partition. It is a FAT32 staging volume containing Apple's Recovery payload in the layout used by OpenCore installer media. The actual APFS container and native Recovery volume are created later by macOS Disk Utility.

## OpenCore and Clover

OpenCore remains the primary loader at the standard UEFI fallback path `EFI/BOOT/BOOTX64.EFI`. Clover is installed separately under `EFI/CLOVER` and contains a minimal configuration with an explicit `OpenCore` entry pointing to `EFI/OC/OpenCore.efi`.

This avoids replacing Windows Boot Manager or changing the Windows BCD. Clover's UEFI layout uses `EFI/CLOVER/CLOVERX64.EFI`; its GUI can scan UEFI entries and custom entries.

The script does **not** modify `{bootmgr}`, `{fwbootmgr}`, Windows partitions, Secure Boot state, or the Windows system disk.

If the firmware does not automatically expose `EFI/CLOVER/CLOVERX64.EFI` as a boot option, use the motherboard's UEFI Boot Override/Add Boot Option facility once to select that EFI executable. Firmware UI capabilities differ, so creating an arbitrary NVRAM boot entry from Windows is deliberately not part of the generic pipeline.

## Safety contract

The script requires:

- administrator PowerShell;
- `-TargetDiskNumber` explicitly supplied;
- `-Force` explicitly supplied;
- target disk reported as RAW/uninitialized;
- target disk with zero existing partitions;
- target disk not marked as Windows boot/system disk;
- existing generated OpenCore EFI/configuration;
- verified `build/recovery/BaseSystem.dmg` and `.chunklist`.

A disk that is already initialized or contains partitions is rejected rather than erased. This is intentional: once `diskpart clean` has executed, a generic script cannot provide a reliable rollback of the user's data.

## Usage

First identify the disk:

```powershell
Get-Disk | Format-Table Number,FriendlyName,PartitionStyle,OperationalStatus,Size -AutoSize
```

Then run:

```powershell
.\scripts\prepare-boot-disk.ps1 -TargetDiskNumber N -Force
```

Replace `N` only after confirming it is the empty target disk.

The script downloads Clover 5175, verifies its pinned SHA-256, creates the GPT layout, stages OpenCore and Recovery, and verifies the final file structure.

## After reboot

The expected first-boot chain is:

```text
UEFI
  -> OpenCore BOOTX64.EFI
      -> OpenCore picker
          -> macOS Recovery / installer
```

or, when selecting the Clover fallback EFI entry from firmware:

```text
UEFI
  -> Clover
      -> OpenCore
          -> macOS Recovery / installer
```

Windows remains independently bootable through its existing boot manager.

Once macOS Setup starts, use Disk Utility with **Show All Devices**, select the target physical disk, and create/erase the remaining space as APFS with GUID Partition Map as appropriate for the installation. Do not format the existing EFI System Partition or the Recovery staging volume from Windows again.

## Validation stage

`collect-validation.sh` and `finalize-validation.sh` are not prerequisites for this first boot. They are intended for a machine that has successfully booted macOS. A machine that cannot yet boot macOS cannot produce genuine runtime validation evidence, so `readiness.ps1` must remain `NeedsValidation` until such evidence exists.
