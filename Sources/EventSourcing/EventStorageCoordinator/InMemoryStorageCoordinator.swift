import DDDCore
import Foundation

/// A thread-safe, in-memory implementation of `EventStorageCoordinator`.
/// Suitable for testing, prototyping, or use cases that do not require persistence.
public actor InMemoryStorageCoordinator: EventStorageCoordinator {

    private var store: [String: (events: [any DomainEvent], revision: UInt64)] = [:]

    public init() {}

    public func fetchEvents(byId id: String) async throws -> (events: [any DomainEvent], latestRevision: UInt64)? {
        guard let entry = store[id] else { return nil }
        return (events: entry.events, latestRevision: entry.revision)
    }

    public func append(events: [any DomainEvent], byId id: String, version: UInt64?, external: [String: String]?) async throws -> UInt64? {
        let existing = store[id]?.events ?? []
        if let expectedVersion = version, let currentRevision = store[id]?.revision {
            guard currentRevision == expectedVersion else {
                throw InMemoryStorageCoordinatorError.versionConflict(expected: expectedVersion, actual: currentRevision)
            }
        }
        let newRevision = UInt64(existing.count + events.count)
        store[id] = (events: existing + events, revision: newRevision)
        return newRevision
    }

    public func purge(byId id: String) async throws {
        store.removeValue(forKey: id)
    }
}

public enum InMemoryStorageCoordinatorError: Error {
    case versionConflict(expected: UInt64, actual: UInt64)
}
