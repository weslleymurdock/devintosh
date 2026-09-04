# `scripts/lib/project-context.ps1`

`project-context.ps1` is the single source of truth for runtime values shared by Devintosh PowerShell stages.

## Loading rule

Every stage must source:

```powershell
. "$PSScriptRoot\lib\common.ps1"
```

`common.ps1` loads `project-context.ps1` automatically. A stage must not independently calculate repository paths, Recovery download/cache paths, macOS version metadata, OpenCore pins, or Recovery integrity pins.

## Central contract

The library exposes one object:

```powershell
$script:Devintosh
```

Its relevant sections are:

- `Devintosh.Version` — selected target id, profile path, macOS family, major version, and complete JSON profile.
- `Devintosh.OpenCore` — repository, version, tag, release URL, release SHA-256, tooling path, and pinned source commit.
- `Devintosh.Recovery` — board ID, MLB, OS type, pinned chunklist SHA-256, external download root, persistent cache root/key/path, and repository build paths.
- `Devintosh.Paths` — repository, build, logs, backups, EFI, OpenCore config, manifests, and hardware inventory paths.

The profile is loaded from `config/versions/<id>.json`. The target is selected through `DEVINTOSH_MACOS_VERSION`; `main.ps1` sets this before launching isolated child stages.

## External Recovery download and persistent cache

Recovery payloads are **never downloaded into the repository**. The global environment variable `DEVINTOSH_RECOVERY_DOWNLOAD_ROOT` defines the persistent external storage root and defaults to:

```text
D:\DevintoshRecovery
```

`D:\` is the initial default because it is a conventional Windows build/workspace drive and is also commonly available as the build volume in CI environments such as GitHub Actions. The value is intentionally centralized so the default can be changed later without modifying individual pipeline stages.

The resulting layout is:

```text
D:\DevintoshRecovery\
└── Cache\
    └── sequoia-Mac-7BA5B2D9E42DDD94-default\
        ├── BaseSystem.dmg
        ├── BaseSystem.chunklist
        └── recovery-manifest.json
```

During a fresh Apple download, the temporary directory is also created below `DEVINTOSH_RECOVERY_DOWNLOAD_ROOT`, for example:

```text
D:\DevintoshRecovery\recovery-download-<guid>\
```

After successful verification, the payload is atomically committed to the persistent cache. Only then is it copied into the disposable repository workspace:

```text
<repo>\build\recovery\
├── BaseSystem.dmg
├── BaseSystem.chunklist
└── recovery-manifest.json
```

The `build\recovery` copy is therefore an installation/build artifact, not the source of truth for the downloaded Recovery. Deleting the repository during a clean retry does not delete the validated Recovery cache.

`DEVINTOSH_RECOVERY_CACHE` points to the external cache root (`D:\DevintoshRecovery\Cache` by default). Both environment variables are exported by the central context and are available to isolated child processes.

The cache is keyed by the target profile, Recovery board ID, and Recovery OS type. A cached payload is never trusted solely because the directory exists. The Recovery stage must verify its manifest, pinned `BaseSystem.chunklist` SHA-256, file presence, and every DMG chunk using the pinned OpenCore `macrecovery.py` verifier before reuse.

## Version coupling

The version profile is the contract boundary between macOS and OpenCore. For each target, `config/versions/<id>.json` defines the macOS identity, OpenCore release/version/source pin, and Recovery identity/integrity pin. Adding another macOS target means adding another profile rather than editing generic stages to contain another hardcoded version.

## Producer/consumer rule

A stage that produces an artifact must use the paths in `$script:Devintosh.Paths` or `$script:Devintosh.Recovery`. A consumer must use those same paths. Do not reconstruct paths with literals such as `build\efi`, `build\recovery`, or a separately calculated Recovery download/cache directory.

Similarly, version-sensitive stages must consume `$script:Devintosh.Version`, `$script:Devintosh.OpenCore`, and `$script:Devintosh.Recovery` instead of embedding OpenCore versions, release URLs, SHA-256 values, board IDs, or chunklist pins.

## Clean-retry invariant

A clean retry may remove the entire repository clone and recreate it from Git. It must **not** remove `DEVINTOSH_RECOVERY_DOWNLOAD_ROOT`. If a valid cache exists there, the Recovery stage must reuse it after local integrity verification and must not contact Apple for another Recovery download.

Conversely, `build\recovery` is disposable and may be recreated from the external cache at any time.

## Why this exists

The pipeline executes stages in isolated Windows PowerShell 5.1 processes. A normal PowerShell variable does not cross that process boundary. The environment variables `DEVINTOSH_MACOS_VERSION`, `DEVINTOSH_RECOVERY_DOWNLOAD_ROOT`, and `DEVINTOSH_RECOVERY_CACHE` select the shared runtime contract in each child, while `project-context.ps1` reconstructs the exact same immutable project contract from source-controlled profile data.

This makes the pipeline deterministic while preserving downloaded, validated Recovery assets across clean source-tree retries and without coupling the generic code to a developer's repository location.
