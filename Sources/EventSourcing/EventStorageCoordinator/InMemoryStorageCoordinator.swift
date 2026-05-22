import DDDCore
import Foundation

/// A thread-safe, in-memory implementation of `EventStore`.
/// Suitable for testing, prototyping, or use cases that do not require persistence.
///
/// Stores typed metadata side-by-side with events. `fetchEvents` returns events
/// as appended — it does NOT populate `event.metadata` on read (the heterogeneous
/// `[any DomainEvent]` makes generic typed assignment impractical). Tests that
/// need to verify metadata round-trip should either inspect the store's
/// `recordedMetadata(byId:)` helper or use the Kurrent integration tests.
public actor InMemoryStorageCoordinator<Metadata: EventMetadata>: EventStore {

    private struct Entry {
        var events: [any DomainEvent]
        var metadata: [Metadata?]   // 1:1 with events; one entry per appended event
        var revision: UInt64
    }

    private var store: [String: Entry] = [:]

    public init() {}

    public func fetchEvents(byId id: String) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)? {
        guard let entry = store[id] else { return nil }
        return (events: entry.events, latestRevision: entry.revision)
    }

    public func fetchEvents(byId id: String, afterRevision revision: UInt64) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)? {
        guard let entry = store[id] else { return nil }
        let startIndex = Int(revision)
        guard startIndex <= entry.events.count else { return nil }
        let newEvents = Array(entry.events[startIndex...])
        return (events: newEvents, latestRevision: entry.revision)
    }

    public func append(
        events: [any DomainEvent],
        byId id: String,
        version: UInt64?,
        metadata: Metadata?
    ) async throws -> UInt64? {
        let existing = store[id]?.events ?? []
        let existingMetadata = store[id]?.metadata ?? []
        if let expectedVersion = version, let currentRevision = store[id]?.revision {
            guard currentRevision == expectedVersion else {
                throw InMemoryStorageCoordinatorError.versionConflict(
                    expected: expectedVersion, actual: currentRevision
                )
            }
        }
        let newMetadata = existingMetadata + Array(repeating: metadata, count: events.count)
        let newRevision = UInt64(existing.count + events.count)
        store[id] = Entry(
            events: existing + events,
            metadata: newMetadata,
            revision: newRevision
        )
        return newRevision
    }

    public func purge(byId id: String) async throws {
        store.removeValue(forKey: id)
    }

    // MARK: - Test inspection helpers

    /// Returns the metadata associated with each appended event (1:1, ordered).
    /// Test-only — production code should not depend on this.
    public func recordedMetadata(byId id: String) async -> [Metadata?] {
        store[id]?.metadata ?? []
    }
}

public enum InMemoryStorageCoordinatorError: Error {
    case versionConflict(expected: UInt64, actual: UInt64)
}
