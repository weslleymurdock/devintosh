# `scripts/lib/storage.ps1`

Provides storage discovery, target safety checks, and target-disk snapshot helpers.

The library is designed to prevent accidental selection of the Windows boot/system disk and is used by preparation stages that need a transactional storage target.
