import Testing
import Foundation
import KurrentDB
import KurrentSupport

/// A conformer written before 1.4: it has no `tombstoneStream`.
// The deprecation warning this conformance emits is the point; do not silence it.
private struct LegacyClient: EventStoreClient {
    func append(events: [EventData], toStream name: String, category: String, expectedRevision: StreamRevision) async throws -> UInt64? { nil }
    func readStream(name: String, from revision: RevisionCursor, resolveLinks: Bool) async throws -> [any RecordedEventLike] { [] }
    func deleteStream(name: String, expectedRevision: StreamRevision) async throws {}
    func subscribePersistent(stream: String, group: String) async throws -> any PersistentSubscriptionSession {
        throw EventStoreClientError.subscriptionGroupNotFound(stream: stream, group: group)
    }
    func ensurePersistentSubscription(stream: String, group: String, settings: PersistentSubscriptionSettings) async throws {}
    func deletePersistentSubscription(stream: String, group: String) async throws {}
}

@Suite("EventStoreClient.tombstoneStream default")
struct TombstoneDefaultTests {
    @Test("a conformer without tombstoneStream still compiles and throws tombstoneUnsupported")
    func defaultThrows() async {
        await #expect(throws: EventStoreClientError.tombstoneUnsupported) {
            try await LegacyClient().tombstoneStream(name: "Order-1")
        }
    }
}
