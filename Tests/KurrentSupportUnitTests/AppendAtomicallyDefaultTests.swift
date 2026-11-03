import Testing
import Foundation
import KurrentDB
import KurrentSupport

/// A conformer written before 1.5: it has no `appendAtomically`.
// The deprecation warning this conformance emits is the point; do not silence it.
private struct PreAtomicClient: EventStoreClient {
    var identity: ObjectIdentifier { ObjectIdentifier(Self.self) }
    func append(events: [EventData], toStream name: String, category: String, expectedRevision: StreamRevision) async throws -> UInt64? { nil }
    func readStream(name: String, from revision: RevisionCursor, resolveLinks: Bool) async throws -> [any RecordedEventLike] { [] }
    func deleteStream(name: String, expectedRevision: StreamRevision) async throws {}
    func tombstoneStream(name: String) async throws {}
    func subscribePersistent(stream: String, group: String) async throws -> any PersistentSubscriptionSession {
        throw EventStoreClientError.subscriptionGroupNotFound(stream: stream, group: group)
    }
    func ensurePersistentSubscription(stream: String, group: String, settings: PersistentSubscriptionSettings) async throws {}
    func deletePersistentSubscription(stream: String, group: String) async throws {}
}

@Suite("EventStoreClient.appendAtomically default")
struct AppendAtomicallyDefaultTests {
    @Test("a conformer without appendAtomically still compiles and throws atomicAppendUnsupported")
    func defaultThrows() async {
        // Called through the existential, the way the unit-of-work backend calls it.
        let client: any EventStoreClient = PreAtomicClient()
        await #expect(throws: EventStoreClientError.atomicAppendUnsupported) {
            _ = try await client.appendAtomically([])
        }
    }

    @Test("StreamConflict values with the same stream, expected and current revision are equal",
          arguments: [StreamRevision.any, .noStream, .streamExists, .at(1)])
    func streamConflictEqualsItself(expected: StreamRevision) {
        #expect(StreamConflict(stream: "a", expected: expected, current: nil) == StreamConflict(stream: "a", expected: expected, current: nil))
        #expect(StreamConflict(stream: "a", expected: expected, current: 4) == StreamConflict(stream: "a", expected: expected, current: 4))
    }

    @Test("StreamConflict values differing in one field are not equal")
    func streamConflictDiffersByField() {
        let conflict = StreamConflict(stream: "a", expected: .at(1), current: nil)
        #expect(conflict == StreamConflict(stream: "a", expected: .at(1), current: nil))
        #expect(conflict != StreamConflict(stream: "a", expected: .at(2), current: nil))
        #expect(conflict != StreamConflict(stream: "b", expected: .at(1), current: nil))
        #expect(conflict != StreamConflict(stream: "a", expected: .at(1), current: 1))
    }

    @Test("StreamConflict values with different kinds of expected revision are not equal",
          arguments: [
            (StreamRevision.any, StreamRevision.noStream),
            (.noStream, .streamExists),
            (.streamExists, .at(0)),
            (.at(0), .any),
          ])
    func streamConflictDiffersByExpectedKind(lhs: StreamRevision, rhs: StreamRevision) {
        #expect(StreamConflict(stream: "a", expected: lhs, current: nil) != StreamConflict(stream: "a", expected: rhs, current: nil))
        #expect(StreamConflict(stream: "a", expected: rhs, current: nil) != StreamConflict(stream: "a", expected: lhs, current: nil))
    }
}
