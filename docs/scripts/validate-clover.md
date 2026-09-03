# validate-clover.ps1

## Purpose

`validate-clover.ps1` is a Windows-side, non-destructive validation stage for a Devintosh disk after macOS has been installed. It verifies the EFI boot chain that Windows can inspect without claiming that hardware compatibility has been proven.

The expected chain is:

```text
UEFI
  -> EFI/CLOVER/CLOVERX64.EFI
  -> Clover config.plist
  -> EFI/OC/OpenCore.efi
  -> macOS
```

The script uses DiskPart to inspect the selected disk and temporarily mounts its EFI System Partition. It then validates the Clover executable, Clover `config.plist`, the expected Clover custom entry for OpenCore, and the OpenCore executable.

## Usage

Explicit disk:

```powershell
.\scripts\validate-clover.ps1 -TargetDiskNumber 1 -Force
```

Interactive safe selection:

```powershell
.\scripts\validate-clover.ps1 -Force
```

The active Windows boot/system disk is protected by the same storage safety policy used by `prepare-boot-disk.ps1`.

## Validation steps

1. Check administrator privileges and `diskpart.exe`/`mountvol.exe`.
2. Select a physical disk and apply the normal boot/system-disk safety check.
3. Run `diskpart` with `select disk N` and `list partition`.
4. Identify the EFI System Partition.
5. Temporarily assign an unused drive letter to the EFI partition.
6. Verify `EFI/CLOVER/CLOVERX64.EFI`, `EFI/CLOVER/config.plist`, and `EFI/OC/OpenCore.efi`.
7. Parse Clover `config.plist` as XML and verify the GUI custom entry points to `\\EFI\\OC\\OpenCore.efi`.
8. Write `build/opencore/clover-validation-report.json`.

The temporary drive letter is removed during cleanup. The script does not repartition, format, erase, or modify the Windows BCD.

## Interpretation

`Valid` means the Windows-visible Clover-to-OpenCore chain is structurally complete and the Clover configuration contains the expected OpenCore hand-off.

It does **not** mean:

- macOS is compatible with the hardware;
- SMBIOS is validated;
- GPU, audio, USB, network, ACPI, or kext runtime compatibility is validated;
- macOS can boot successfully in every firmware configuration.

Those claims require the native macOS validation stages.
