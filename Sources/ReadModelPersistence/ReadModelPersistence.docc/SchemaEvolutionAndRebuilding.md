# Schema evolution and rebuilding

Change a read model's shape without leaving undecodable snapshots behind.

## No rebuild needed

- Adding an **optional** property (`var note: String? = nil`). Old snapshots decode with `nil`;
  the value fills in as the read model's stream receives new events — or rebuild to fill it now.

## Rebuild required

Old snapshots would fail to decode (and the runner would nack the event forever) or would be
silently orphaned after any of these:

- a property made required, or its type changed
- a different `readModelTypeName` (including renaming the Swift type when relying on the default)
- a different snapshot write mode or base table name
- a projector change that must be applied to history

## Procedure

1. Stop every consumer of the subscription group.
2. Run the rebuild:

   ```swift
   try await KurrentProjection.rebuild(
       readModels: [OrderSummary.self],
       snapshots: PostgresReadModelSnapshots(client: pgClient),
       client: kurrentClient,
       stream: "$ce-Order",
       group: "order-summary"
   )
   ```

3. Deploy the new version. The runner replays the stream from the start and writes fresh snapshots.

Every step is idempotent; re-run after a partial failure.

## Why purging alone is not enough

The subscription group's checkpoint is already past the existing events. After a purge alone,
only read models whose stream receives a new event are rebuilt; the rest stay missing. The rebuild
deletes and recreates the group from the start so every event is replayed. Read models sharing the
group that you did not list are replayed too — their stored revisions make that a no-op.
