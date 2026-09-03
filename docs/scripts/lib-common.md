# `scripts/lib/common.ps1`

Shared runtime definitions for the PowerShell pipeline.

It establishes repository/build/log/backup paths, strict execution conventions, administrator detection, timestamps, safe invocation helpers, and the project exit-code contract.

Scripts source this library instead of duplicating global runtime behavior.
