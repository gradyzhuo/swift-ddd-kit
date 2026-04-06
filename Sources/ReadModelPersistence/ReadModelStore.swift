import DDDCore
import EventSourcing

public struct StoredReadModel<Model: ReadModel & Sendable>: Sendable {
    public let readModel: Model
    public let revision: UInt64

    public init(readModel: Model, revision: UInt64) {
        self.readModel = readModel
        self.revision = revision
    }
}

/// Abstraction for persisting and retrieving read model snapshots.
/// Implement this protocol backed by PostgreSQL, SQLite, Redis, etc.
public protocol ReadModelStore: Sendable {
    associatedtype Model: ReadModel & Sendable where Model.ID: Sendable

    /// Fetch the stored read model and its last-applied revision.
    /// Returns nil if no snapshot exists yet (first-time projection).
    func fetch(byId id: Model.ID) async throws -> StoredReadModel<Model>?

    /// Save (upsert) a read model snapshot along with the revision it was built from.
    func save(readModel: Model, revision: UInt64) async throws

    /// Delete a stored read model snapshot.
    func delete(byId id: Model.ID) async throws
}
