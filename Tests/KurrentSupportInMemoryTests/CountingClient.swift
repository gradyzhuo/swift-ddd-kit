import Foundation
import KurrentDB
import KurrentSupport
import KurrentSupportInMemory
import Synchronization

/// Forwards every call to a wrapped `InMemoryEventStoreClient`, counting `append` and
/// `appendAtomically` calls. Optionally adds `revisionOffset` to the revisions both append
/// methods return, or makes both throw `errorToThrow` without forwarding.
final class CountingClient: EventStoreClient {
    let wrapped: InMemoryEventStoreClient
    private let revisionOffset: UInt64
    private let errorToThrow: (any Error)?
    private let calls = Mutex<[String: Int]>([:])

    init(wrapping wrapped: InMemoryEventStoreClient, revisionOffset: UInt64 = 0, errorToThrow: (any Error)? = nil) {
        self.wrapped = wrapped
        self.revisionOffset = revisionOffset
        self.errorToThrow = errorToThrow
    }

    /// How many times `append(events:toStream:category:expectedRevision:)` was called.
    var appendCount: Int { calls.withLock { $0["append", default: 0] } }

    /// How many times `appendAtomically(_:)` was called.
    var appendAtomicallyCount: Int { calls.withLock { $0["appendAtomically", default: 0] } }

    private func record(_ method: String) {
        calls.withLock { $0[method, default: 0] += 1 }
    }

    var identity: ObjectIdentifier { wrapped.identity }

    func append(events: [EventData], toStream name: String, category: String, expectedRevision: StreamRevision) async throws -> UInt64? {
        record("append")
        if let errorToThrow { throw errorToThrow }
        let revision = try await wrapped.append(events: events, toStream: name, category: category, expectedRevision: expectedRevision)
        return revision.map { $0 + revisionOffset }
    }

    func appendAtomically(_ batches: [StreamBatch]) async throws -> [StreamBatchResult] {
        record("appendAtomically")
        if let errorToThrow { throw errorToThrow }
        let results = try await wrapped.appendAtomically(batches)
        return results.map { StreamBatchResult(stream: $0.stream, revision: $0.revision + revisionOffset) }
    }

    func readStream(name: String, from revision: RevisionCursor, resolveLinks: Bool) async throws -> [any RecordedEventLike] {
        try await wrapped.readStream(name: name, from: revision, resolveLinks: resolveLinks)
    }

    func deleteStream(name: String, expectedRevision: StreamRevision) async throws {
        try await wrapped.deleteStream(name: name, expectedRevision: expectedRevision)
    }

    func tombstoneStream(name: String) async throws {
        try await wrapped.tombstoneStream(name: name)
    }

    func subscribePersistent(stream: String, group: String) async throws -> any PersistentSubscriptionSession {
        try await wrapped.subscribePersistent(stream: stream, group: group)
    }

    func ensurePersistentSubscription(stream: String, group: String, settings: PersistentSubscriptionSettings) async throws {
        try await wrapped.ensurePersistentSubscription(stream: stream, group: group, settings: settings)
    }

    func deletePersistentSubscription(stream: String, group: String) async throws {
        try await wrapped.deletePersistentSubscription(stream: stream, group: group)
    }
}
