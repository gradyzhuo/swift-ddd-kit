/// A snapshot backend that can drop every snapshot of the given read model types at once.
///
/// Snapshots are a disposable projection cache — never the source of truth — so the
/// recovery path for any read model schema change is "purge, then replay from the start".
/// `KurrentProjection.rebuild` drives that flow through this protocol, which keeps it
/// independent of where snapshots live (Postgres, memory, or a future stream-backed store).
public protocol ReadModelSnapshotPurging: Sendable {
    /// Deletes every snapshot whose read model type name (`ReadModel.readModelTypeName`)
    /// is in `typeNames`. Idempotent: purging types with no snapshots succeeds.
    func purgeSnapshots(ofTypes typeNames: [String]) async throws
}
