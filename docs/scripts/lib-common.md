# `scripts/lib/common.ps1`

Shared runtime definitions for the PowerShell pipeline.

It establishes en-US culture, the project exit-code contract, repository/build/log/backup paths, strict execution conventions, administrator detection, timestamps, safe invocation helpers, and loads the centralized `scripts/lib/project-context.ps1` contract.

Every pipeline stage must source this library:

```powershell
. "$PSScriptRoot\lib\common.ps1"
```

That single import gives the stage the same `$script:Devintosh` object used by every other stage. The object contains the selected macOS profile, its OpenCore and Recovery contracts, canonical generated-artifact paths, and the persistent Recovery cache path.

Do not duplicate or independently calculate these values in individual scripts. See [`lib-project-context.md`](lib-project-context.md) for the complete contract and cache/version-coupling rules.
