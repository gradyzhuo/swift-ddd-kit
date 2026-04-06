import DDDCore
import EventSourcing

/// In-memory read model store for testing and prototyping.
public actor InMemoryReadModelStore<Model: ReadModel & Sendable>: ReadModelStore where Model.ID: Sendable {

    private var storage: [Model.ID: StoredReadModel<Model>] = [:]

    public init() {}

    public func fetch(byId id: Model.ID) async throws -> StoredReadModel<Model>? {
        storage[id]
    }

    public func save(readModel: Model, revision: UInt64) async throws {
        storage[readModel.id] = StoredReadModel(readModel: readModel, revision: revision)
    }

    public func delete(byId id: Model.ID) async throws {
        storage.removeValue(forKey: id)
    }
}
