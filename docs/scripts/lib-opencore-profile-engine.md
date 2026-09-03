# `scripts/lib/opencore-profile-engine.ps1`

Generic engine for applying typed declarative OpenCore plist fragments.

Supported leaf descriptors are boolean, integer, string, and data values. Data can be expressed as hexadecimal or base64. The engine recursively maps JSON fragment paths into the OpenCore plist and detects conflicting writes.

Profiles marked `opencore.policy = validation-required` are deliberately skipped. The engine contains no hardware identifiers and no hardware-specific branches.
