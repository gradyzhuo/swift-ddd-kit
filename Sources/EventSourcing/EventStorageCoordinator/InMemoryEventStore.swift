import DDDCore
import Foundation

/// A thread-safe, in-memory `EventStore` that follows the `EventStore` contract:
/// revisions start at 0, `version: nil` requires a new stream, a mismatch throws
/// `DDDError.commitConflict`, and `purge` makes an id permanently unwritable.
///
/// Events are kept as appended — no serialization, no mapper — so `fetchEvents`
/// does NOT populate `event.metadata`. Use `recordedMetadata(byId:)` to check
/// what `append` received.
public actor InMemoryEventStore<Metadata: EventMetadata>: EventStore {

    private struct Entry {
        var events: [any DomainEvent]
        var metadata: [Metadata?]   // 1:1 with events
    }

    private var store: [String: Entry] = [:]
    private var purged: Set<String> = []

    public init() {}

    public func fetchEvents(byId id: String) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)? {
        guard let entry = store[id] else { return nil }
        return (events: entry.events, latestRevision: UInt64(entry.events.count - 1))
    }

    public func fetchEvents(byId id: String, afterRevision revision: UInt64) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)? {
        guard let entry = store[id] else { return nil }
        // Compare in UInt64 first: `Int(revision) + 1` traps for revisions near UInt64.max.
        guard revision < UInt64(entry.events.count - 1) else {
            return (events: [], latestRevision: revision)
        }
        let start = Int(revision) + 1
        return (events: Array(entry.events[start...]), latestRevision: UInt64(entry.events.count - 1))
    }

    public func append(
        events: [any DomainEvent],
        byId id: String,
        version: UInt64?,
        metadata: Metadata?
    ) async throws -> UInt64? {
        guard !events.isEmpty else { return nil }
        guard !purged.contains(id) else { throw DDDError.streamPurged(id: id) }

        var entry = store[id] ?? Entry(events: [], metadata: [])
        let tail: UInt64? = entry.events.isEmpty ? nil : UInt64(entry.events.count - 1)
        guard tail == version else {
            if let replayed = Self.idempotentRevision(of: events, in: entry.events, expected: version) {
                return replayed
            }
            throw DDDError.commitConflict(id: id, expected: version, actual: tail)
        }
        entry.events.append(contentsOf: events)
        entry.metadata.append(contentsOf: Array(repeating: metadata, count: events.count))
        store[id] = entry
        return UInt64(entry.events.count - 1)
    }

    public func purge(byId id: String) async throws {
        purged.insert(id)
        store.removeValue(forKey: id)
    }

    /// KurrentDB's id de-duplication: a batch whose ids equal the stored events
    /// right after `expected` was already written, so answer with its last revision.
    private static func idempotentRevision(
        of events: [any DomainEvent], in stored: [any DomainEvent], expected: UInt64?
    ) -> UInt64? {
        let start: Int
        if let expected {
            // Bail out in UInt64 before converting: `Int(expected) + 1` traps for
            // versions near UInt64.max, and such a version can never match anyway.
            guard expected < UInt64(stored.count) else { return nil }
            start = Int(expected) + 1
        } else {
            start = 0
        }
        let end = start + events.count
        guard end <= stored.count else { return nil }
        guard stored[start..<end].map({ $0.id }) == events.map({ $0.id }) else { return nil }
        return UInt64(end - 1)
    }

    // MARK: - Test inspection helpers

    /// Returns the metadata associated with each appended event (1:1, ordered).
    /// Test-only — production code should not depend on this.
    public func recordedMetadata(byId id: String) async -> [Metadata?] {
        store[id]?.metadata ?? []
    }
}

@available(*, deprecated, message: "No longer thrown. InMemoryEventStore throws DDDError.commitConflict.")
public enum InMemoryStorageCoordinatorError: Error {
    case versionConflict(expected: UInt64, actual: UInt64)
}

@available(*, deprecated, renamed: "InMemoryEventStore", message: "Renamed in 1.5 and now follows the EventStore contract: revisions start at 0, `version: nil` requires a new stream, conflicts throw DDDError.commitConflict. Removed in 1.6 at the earliest.")
public typealias InMemoryStorageCoordinator<Metadata: EventMetadata> = InMemoryEventStore<Metadata>
