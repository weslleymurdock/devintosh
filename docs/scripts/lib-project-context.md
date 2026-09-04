# `scripts/lib/project-context.ps1`

`project-context.ps1` is the single source of truth for runtime values shared by Devintosh PowerShell stages.

## Loading rule

Every stage must source:

```powershell
. "$PSScriptRoot\lib\common.ps1"
```

`common.ps1` loads `project-context.ps1` automatically. A stage must not independently calculate repository paths, Recovery cache paths, macOS version metadata, OpenCore pins, or Recovery integrity pins.

## Central contract

The library exposes one object:

```powershell
$script:Devintosh
```

Its relevant sections are:

- `Devintosh.Version` — selected target id, profile path, macOS family, major version, and complete JSON profile.
- `Devintosh.OpenCore` — repository, version, tag, release URL, release SHA-256, tooling path, and pinned source commit.
- `Devintosh.Recovery` — board ID, MLB, OS type, pinned chunklist SHA-256, persistent cache root/key/path, and repository build paths.
- `Devintosh.Paths` — repository, build, logs, backups, EFI, OpenCore config, manifests, and hardware inventory paths.

The profile is loaded from `config/versions/<id>.json`. The target is selected through `DEVINTOSH_MACOS_VERSION`; `main.ps1` sets this before launching isolated child stages.

## Persistent Recovery cache

`DEVINTOSH_RECOVERY_CACHE` is an environment variable created by the central context. Its value is derived from the root of the drive containing the repository clone:

```text
E:\dev\devintosh
        |
        +-- drive root: E:\
                |
                +-- E:\DevintoshRecoveryCache
```

The cache is therefore outside the repository and survives removal/re-cloning of the source tree.

The cache is keyed by the target profile, Recovery board ID, and Recovery OS type. A cached payload is never trusted solely because the directory exists. The Recovery stage must verify its manifest, pinned `BaseSystem.chunklist` SHA-256, file presence, and every DMG chunk using the pinned OpenCore `macrecovery.py` verifier before reuse.

## Version coupling

The version profile is the contract boundary between macOS and OpenCore. For each target, `config/versions/<id>.json` defines the macOS identity, OpenCore release/version/source pin, and Recovery identity/integrity pin. Adding another macOS target means adding another profile rather than editing generic stages to contain another hardcoded version.

## Producer/consumer rule

A stage that produces an artifact must use the paths in `$script:Devintosh.Paths` or `$script:Devintosh.Recovery`. A consumer must use those same paths. Do not reconstruct paths with literals such as `build\efi`, `build\recovery`, or a separately calculated cache directory.

Similarly, version-sensitive stages must consume `$script:Devintosh.Version`, `$script:Devintosh.OpenCore`, and `$script:Devintosh.Recovery` instead of embedding OpenCore versions, release URLs, SHA-256 values, board IDs, or chunklist pins.

## Why this exists

The pipeline executes stages in isolated Windows PowerShell 5.1 processes. A normal PowerShell variable does not cross that process boundary. The environment variable `DEVINTOSH_MACOS_VERSION` selects the target in each child, while `project-context.ps1` reconstructs the exact same immutable project contract from source-controlled profile data. The persistent cache location is also exported through `DEVINTOSH_RECOVERY_CACHE`.

This makes the contract deterministic without coupling the generic code to any developer's hardware.
