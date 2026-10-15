# Snapshot write modes

Choose what happens when two writes for the same read model race.

## Overview

| Mode | Table (default base) | On an existing row |
|---|---|---|
| ``SnapshotWriteMode/monotonic`` (default) | `read_model_snapshots_monotonic` | replaced only by a **strictly newer** revision |
| ``SnapshotWriteMode/overwrite`` | `read_model_snapshots` | always replaced |

### Why monotonic is the default

Two consumers can fold the same read model concurrently — several instances, or a nacked event
redelivered out of order. Consumer A folds to revision 6 and commits; consumer B, which stopped at
revision 5, commits afterwards. With `.overwrite` the snapshot rolls back to 5 until the stream
receives another event. With `.monotonic` B's write is skipped: every snapshot is a complete fold
up to its revision, so keeping the highest revision is always correct.

A monotonic write with an older or equal revision is skipped silently — the store logs it at
debug level (`skipped stale snapshot write`) and does not throw, so a redelivered event is a no-op.

### When to choose overwrite

`.overwrite` is the pre-existing last-write-wins behaviour. It is appropriate for a single consumer
with in-order delivery, or for keeping an existing `read_model_snapshots` table as it is.

### Separate tables

Each mode writes its own table, so switching never mixes rows written under different rules.
Switching modes (or the base `tableName`) leaves the new table empty — rebuild afterwards
(see ``PostgresReadModelSnapshots`` and `KurrentProjection.rebuild`). Pass the same
`tableName`/`writeMode` to `PostgresReadModelMigration.createTable`, every store, and
`PostgresReadModelSnapshots`.
