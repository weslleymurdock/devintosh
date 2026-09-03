# `download-recovery.ps1`

Downloads the macOS Recovery assets declared by the selected macOS version configuration.

## Usage

```powershell
.\scripts\download-recovery.ps1
```

The version configuration under `config/versions` provides the Apple board identifier and the pinned OpenCore `macrecovery` source used for the acquisition.

## Integrity

The Recovery download is verified using the checks performed by Apple's Recovery acquisition flow. Generated Recovery assets remain under `build/` and are not committed to the repository.

## Design

The script does not embed a developer-specific machine model. Version-specific data belongs in `config/versions`.
