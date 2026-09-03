# `validate.ps1`

Validates the Windows host against the current macOS compatibility baseline.

## Usage

```powershell
.\scripts\validate.ps1
```

## Role

This is the entry point for compatibility assessment. It inventories relevant CPU, GPU, firmware, and platform facts and reports compatibility without modifying the host.

The script is intentionally conservative: a warning or an unresolved hardware detail does not cause the generic pipeline to invent a configuration.

## Output

The result is a human-readable compatibility assessment. Proceed to `prepare.ps1` when the host is considered a candidate.
