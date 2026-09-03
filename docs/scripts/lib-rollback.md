# `scripts/lib/rollback.ps1`

Provides transaction and rollback primitives for mutating pipeline stages.

Stages register restoration actions before changing generated state. On failure, registered actions are executed in rollback order and the stage reports a rollback failure separately when restoration itself fails.
