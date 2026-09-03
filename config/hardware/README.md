# Hardware Profiles

Hardware profiles are declarative and hardware-agnostic. The PowerShell configuration engine discovers every JSON file under `config/hardware`, evaluates its `match` rules against the live Windows hardware inventory, and applies only explicitly declared OpenCore fragments.

## Profile structure

```json
{
  "schemaVersion": 1,
  "id": "example-device",
  "description": "Example hardware capability.",
  "match": {
    "gpuVendorId": "1002",
    "gpuDeviceIds": ["XXXX"]
  },
  "capabilities": {
    "gpu": true,
    "requiresGpuValidation": true
  },
  "opencore": {
    "policy": "validation-required"
  }
}
```

Supported matching predicates are implemented by `configure-opencore.ps1` and include CPU, platform/motherboard, GPU, network, audio, USB, ACPI, and nested `anyOf` rules.

## Declarative plist fragments

A profile may expose an `opencore.plist` object. Its tree mirrors the OpenCore plist structure. Leaves are typed descriptors:

```json
{
  "opencore": {
    "plist": {
      "Kernel": {
        "Quirks": {
          "SomeBoolean": {
            "type": "boolean",
            "value": true
          }
        },
        "Emulate": {
          "MinKernel": {
            "type": "string",
            "value": "19.0.0"
          },
          "Cpuid1Data": {
            "type": "data",
            "format": "hex",
            "value": "AABBCCDD"
          }
        }
      }
    }
  }
}
```

Supported descriptor types:

- `boolean` — JSON boolean value.
- `integer` — integral value.
- `string` — UTF-8 string.
- `data` — `base64` or hexadecimal (`format: hex`), converted to plist `<data>`.

The fragment engine creates missing dictionaries and replaces only the declared leaf values. It never uses hardware-specific `if`/`switch` branches.

## Validation policy

If `opencore.policy` is `validation-required`, no `opencore.plist` fragment from that profile is applied. This is intentional for hardware where Windows cannot safely prove the required macOS configuration, such as GPU spoofing, USB port maps, ACPI patches, or audio layout IDs.

If two matched profiles attempt different values at the same plist path, the application stage fails before modifying the candidate. This prevents profile ordering from silently deciding a hardware configuration.

Unknown hardware remains supported by the pipeline: it is reported as `NeedsProfile` rather than being mapped to an unrelated profile.
