import KurrentDB
import Logging
import EventSourcing
import ReadModelPersistence

extension KurrentProjection {

    /// Rebuilds read models from scratch: deletes the subscription group, purges the
    /// listed read models' snapshots, and recreates the group (from the start by default),
    /// so the next runner start replays every event.
    ///
    /// Use it after any change that makes stored snapshots unreadable or wrong — a
    /// field made required, a type change, a new `readModelTypeName`, a different
    /// snapshot write mode or table.
    ///
    /// **Stop every consumer of `group` first**, run this, then deploy the new
    /// version. Deleting the group first cuts off a consumer that was missed, but it
    /// may still be running the old schema.
    ///
    /// Every step is idempotent — re-run after a partial failure. Read models sharing
    /// the group but not listed are replayed too; their stored revisions make that a no-op.
    ///
    /// `snapshots` is a single backend: read models stored in different tables or write
    /// modes need one `rebuild` call per purger (or a purger that fans out).
    public static func rebuild(
        readModels: [any ReadModel.Type],
        snapshots: any ReadModelSnapshotPurging,
        eventStore: any EventStoreClient,
        stream: String,
        group: String,
        settings: PersistentSubscriptionSettings = .init(startFrom: .start),
        logger: Logger = Logger(label: "KurrentProjection.rebuild")
    ) async throws {
        let typeNames = readModels.map { $0.readModelTypeName }
        logger.notice("rebuild \(stream)/\(group): deleting group, purging \(typeNames)")
        try await eventStore.deletePersistentSubscription(stream: stream, group: group)
        try await snapshots.purgeSnapshots(ofTypes: typeNames)
        try await eventStore.ensurePersistentSubscription(stream: stream, group: group, settings: settings)
        logger.notice("rebuild \(stream)/\(group): group recreated (startFrom: \(settings.startFrom)); restart consumers to replay")
    }

    /// Convenience for a real KurrentDB connection.
    public static func rebuild(
        readModels: [any ReadModel.Type],
        snapshots: any ReadModelSnapshotPurging,
        client: KurrentDBClient,
        stream: String,
        group: String,
        settings: PersistentSubscriptionSettings = .init(startFrom: .start),
        logger: Logger = Logger(label: "KurrentProjection.rebuild")
    ) async throws {
        try await rebuild(
            readModels: readModels, snapshots: snapshots,
            eventStore: LiveEventStoreClient(client: client),
            stream: stream, group: group, settings: settings, logger: logger
        )
    }
}
