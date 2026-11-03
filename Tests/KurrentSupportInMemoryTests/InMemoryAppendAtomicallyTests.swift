import Testing
import Foundation
import KurrentDB
import KurrentSupport
import KurrentSupportInMemory

private struct SampleEvent: Codable, Sendable, Equatable {
    let text: String
}

/// `JSONEncoder` refuses a non-finite `Double`, so this payload fails to encode.
private struct Measured: Codable, Sendable {
    let value: Double
}

private func sample(_ text: String) -> EventData {
    EventData(eventType: "SampleEvent", model: SampleEvent(text: text))
}

private func batch(_ stream: String, _ expected: StreamRevision, _ events: [EventData]) -> StreamBatch {
    StreamBatch(stream: stream, category: "Order", expectedRevision: expected, events: events)
}

/// Results come back in no particular order; sort them to compare.
private func sortedByStream(_ results: [StreamBatchResult]) -> [StreamBatchResult] {
    results.sorted { $0.stream < $1.stream }
}

private func storedIds(_ client: InMemoryEventStoreClient, _ stream: String) async throws -> [UUID] {
    try await client.readStream(name: stream, from: .start, resolveLinks: true).map(\.id)
}

private func storedRevisions(_ client: InMemoryEventStoreClient, _ stream: String) async throws -> [UInt64] {
    try await client.readStream(name: stream, from: .start, resolveLinks: true).map(\.revision)
}

private func expectNotWritten(_ client: InMemoryEventStoreClient, _ stream: String) async {
    await #expect(throws: EventStoreClientError.streamNotFound) {
        _ = try await client.readStream(name: stream, from: .start, resolveLinks: true)
    }
}

/// Every event id the session delivered, in order. Delete the group first: that ends the
/// session after the deliveries it has already queued, so this never waits.
private func deliveredIds(_ session: any PersistentSubscriptionSession) async throws -> [UUID] {
    var ids: [UUID] = []
    do {
        for try await delivery in session.events {
            ids.append(delivery.event.id)
        }
    } catch EventStoreClientError.subscriptionGroupNotFound {
        // The deleted group ended the session.
    }
    return ids
}

@Suite("InMemoryEventStoreClient — appendAtomically")
struct InMemoryAppendAtomicallyTests {

    @Test("two new streams each start at revision 0; each result is the stream's last revision")
    func twoNewStreamsGetRevisionZeroEach() async throws {
        let client = InMemoryEventStoreClient()
        let a = [sample("a1")]
        let b = [sample("b1"), sample("b2")]

        let results = try await client.appendAtomically([
            batch("Order-A", .noStream, a),
            batch("Order-B", .noStream, b),
        ])

        #expect(sortedByStream(results) == [
            StreamBatchResult(stream: "Order-A", revision: 0),
            StreamBatchResult(stream: "Order-B", revision: 1),
        ])
        #expect(try await storedIds(client, "Order-A") == a.map(\.id))
        #expect(try await storedRevisions(client, "Order-A") == [0])
        #expect(try await storedIds(client, "Order-B") == b.map(\.id))
        #expect(try await storedRevisions(client, "Order-B") == [0, 1])
    }

    @Test("every expected revision is checked before anything is written")
    func allChecksBeforeAnyWrite() async throws {
        let client = InMemoryEventStoreClient()

        await #expect(throws: EventStoreClientError.consistencyViolations([
            StreamConflict(stream: "Order-B", expected: .at(3), current: nil),
        ])) {
            _ = try await client.appendAtomically([
                batch("Order-A", .noStream, [sample("a1")]),
                batch("Order-B", .at(3), [sample("b1")]),
            ])
        }

        await expectNotWritten(client, "Order-A")
        await expectNotWritten(client, "Order-B")
    }

    @Test("every mismatched stream is reported, not only the first")
    func everyViolationReported() async throws {
        let client = InMemoryEventStoreClient()
        _ = try await client.append(events: [sample("a0")], toStream: "Order-A", category: "Order", expectedRevision: .noStream)
        _ = try await client.append(events: [sample("b0"), sample("b1")], toStream: "Order-B", category: "Order", expectedRevision: .noStream)

        await #expect(throws: EventStoreClientError.consistencyViolations([
            StreamConflict(stream: "Order-A", expected: .noStream, current: 0),
            StreamConflict(stream: "Order-B", expected: .at(5), current: 1),
            StreamConflict(stream: "Order-C", expected: .streamExists, current: nil),
        ])) {
            _ = try await client.appendAtomically([
                batch("Order-A", .noStream, [sample("a1")]),
                batch("Order-B", .at(5), [sample("b2")]),
                batch("Order-C", .streamExists, [sample("c1")]),
            ])
        }

        #expect(try await storedRevisions(client, "Order-A") == [0])
        #expect(try await storedRevisions(client, "Order-B") == [0, 1])
        await expectNotWritten(client, "Order-C")
    }

    @Test("a tombstoned stream throws resourceDeleted and nothing is written")
    func tombstonedStreamThrowsResourceDeletedAndWritesNothing() async throws {
        let client = InMemoryEventStoreClient()
        try await client.tombstoneStream(name: "Order-T")

        await #expect(throws: KurrentError.resourceDeleted(resource: "Order-T")) {
            _ = try await client.appendAtomically([
                batch("Order-U", .noStream, [sample("u1")]),
                batch("Order-T", .noStream, [sample("t1")]),
            ])
        }

        await expectNotWritten(client, "Order-U")
    }

    @Test("with several tombstoned streams, the first in batch order is reported")
    func firstTombstonedBatchIsReported() async throws {
        let client = InMemoryEventStoreClient()
        try await client.tombstoneStream(name: "Order-T1")
        try await client.tombstoneStream(name: "Order-T2")

        await #expect(throws: KurrentError.resourceDeleted(resource: "Order-T2")) {
            _ = try await client.appendAtomically([
                batch("Order-T2", .noStream, [sample("t2")]),
                batch("Order-T1", .noStream, [sample("t1")]),
            ])
        }
    }

    @Test("a tombstoned stream wins over a revision conflict listed before it")
    func tombstonedWinsOverConflict() async throws {
        let client = InMemoryEventStoreClient()
        try await client.tombstoneStream(name: "Order-A")

        await #expect(throws: KurrentError.resourceDeleted(resource: "Order-A")) {
            _ = try await client.appendAtomically([
                batch("Order-B", .at(3), [sample("b1")]),
                batch("Order-A", .noStream, [sample("a1")]),
            ])
        }

        await expectNotWritten(client, "Order-B")
    }

    @Test("resending every batch returns the original revisions and writes nothing")
    func resendingEveryBatchReturnsOriginalRevisions() async throws {
        let client = InMemoryEventStoreClient()
        _ = try await client.append(events: [sample("a0")], toStream: "Order-A", category: "Order", expectedRevision: .noStream)
        let batches = [
            batch("Order-A", .at(0), [sample("a1")]),
            batch("Order-B", .noStream, [sample("b1"), sample("b2")]),
        ]

        let first = try await client.appendAtomically(batches)
        let resent = try await client.appendAtomically(batches)

        #expect(sortedByStream(first) == [
            StreamBatchResult(stream: "Order-A", revision: 1),
            StreamBatchResult(stream: "Order-B", revision: 1),
        ])
        #expect(sortedByStream(resent) == sortedByStream(first))
        #expect(try await storedRevisions(client, "Order-A") == [0, 1])
        #expect(try await storedRevisions(client, "Order-B") == [0, 1])
    }

    @Test("resending only some batches is an ordinary conflict; nothing is written")
    func partialResendIsAnOrdinaryConflict() async throws {
        let client = InMemoryEventStoreClient()
        let a = batch("Order-A", .noStream, [sample("a1")])
        _ = try await client.appendAtomically([a, batch("Order-B", .noStream, [sample("b1")])])

        await #expect(throws: EventStoreClientError.consistencyViolations([
            StreamConflict(stream: "Order-A", expected: .noStream, current: 0),
        ])) {
            _ = try await client.appendAtomically([a, batch("Order-C", .noStream, [sample("c1")])])
        }

        #expect(try await storedRevisions(client, "Order-A") == [0])
        await expectNotWritten(client, "Order-C")
    }

    @Test("the global sequence continues across batches: a $ce subscription sees A's events, then B's")
    func globalSequenceContinuesAcrossBatches() async throws {
        let client = InMemoryEventStoreClient()
        let b0 = sample("b0")
        _ = try await client.append(events: [b0], toStream: "Order-B", category: "Order", expectedRevision: .noStream)
        try await client.ensurePersistentSubscription(stream: "$ce-Order", group: "live", settings: .init(startFrom: .end))
        let live = try await client.subscribePersistent(stream: "$ce-Order", group: "live")
        let a = [sample("a1"), sample("a2")]
        let b = [sample("b1"), sample("b2")]

        _ = try await client.appendAtomically([
            batch("Order-A", .noStream, a),
            batch("Order-B", .at(0), b),
        ])
        // A group created now replays the store ordered by the global sequence.
        try await client.ensurePersistentSubscription(stream: "$ce-Order", group: "replay", settings: .init(startFrom: .start))
        let replay = try await client.subscribePersistent(stream: "$ce-Order", group: "replay")
        try await client.deletePersistentSubscription(stream: "$ce-Order", group: "live")
        try await client.deletePersistentSubscription(stream: "$ce-Order", group: "replay")

        #expect(try await deliveredIds(live) == (a + b).map(\.id))
        #expect(try await deliveredIds(replay) == ([b0] + a + b).map(\.id))
    }

    @Test("a payload that cannot be encoded fails the call before any stream is written")
    func unencodablePayloadWritesNothing() async throws {
        let client = InMemoryEventStoreClient()
        let unencodable = EventData(eventType: "Measured", model: Measured(value: .nan))

        await #expect(throws: EncodingError.self) {
            _ = try await client.appendAtomically([
                batch("Order-A", .noStream, [sample("a1")]),
                batch("Order-B", .noStream, [unencodable]),
            ])
        }

        await expectNotWritten(client, "Order-A")
        await expectNotWritten(client, "Order-B")
    }

    @Test("identity is stable for one instance and differs between instances")
    func identityIsStablePerInstance() {
        let first = InMemoryEventStoreClient()
        let second = InMemoryEventStoreClient()

        #expect(first.identity == first.identity)
        #expect(first.identity != second.identity)
    }
}
