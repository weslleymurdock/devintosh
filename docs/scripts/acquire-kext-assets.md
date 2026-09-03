# `acquire-kext-assets.ps1`

Downloads, verifies, extracts, and stages the kext payloads resolved by `resolve-kexts.ps1`.

## Usage

```powershell
.\scripts\acquire-kext-assets.ps1 -Force
```

## Integrity

Every archive is verified against the catalog SHA-256 before extraction. Declared payloads must resolve to exactly one bundle. When an archive contains multiple candidates, an explicit catalog `payloadSelection` rule may select the intended archive layout; ambiguity otherwise fails safely.

The stage also records per-payload directory hashes and license metadata.

## Outputs

- `build/efi/EFI/OC/Kexts/`
- `build/opencore/kext-assets.json`
- `build/opencore/licenses/`

This stage does not modify `Kernel -> Add`; composition is deliberately separated into `compose-opencore-kexts.ps1`.
