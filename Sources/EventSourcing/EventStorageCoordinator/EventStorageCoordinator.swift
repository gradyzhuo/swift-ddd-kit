import DDDCore
import Foundation

public protocol EventStore: Sendable {
    associatedtype Metadata: EventMetadata

    func fetchEvents(byId id: String) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)?
    func fetchEvents(byId id: String, afterRevision revision: UInt64) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)?
    func append(
        events: [any DomainEvent],
        byId id: String,
        version: UInt64?,
        metadata: Metadata?
    ) async throws -> UInt64?
    func purge(byId id: String) async throws
}

extension EventStore {
    /// Default: fetches all events then drops those already processed.
    /// Suitable for count-based revision schemes. Stores with different
    /// revision semantics (e.g. 0-based index) should override for correctness.
    public func fetchEvents(byId id: String, afterRevision revision: UInt64) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)? {
        guard let result = try await fetchEvents(byId: id) else { return nil }
        let newEvents = Array(result.events.dropFirst(Int(revision)))
        return (events: newEvents, latestRevision: result.latestRevision)
    }
}
