import Testing
import Foundation
import KurrentDB
import KurrentSupport
import KurrentSupportInMemory

private struct SampleEvent: Codable, Sendable, Equatable {
    let text: String
}

private func sampleEvents(_ count: Int) -> [EventData] {
    (0..<count).map { EventData(eventType: "SampleEvent", model: SampleEvent(text: "\($0)")) }
}

@Suite("InMemoryEventStoreClient — storage")
struct InMemoryEventStoreClientTests {

    @Test("append then readStream(.start) round-trips events in order")
    func appendAndReadRoundTrip() async throws {
        let client = InMemoryEventStoreClient()
        let e1 = EventData(eventType: "SampleEvent", model: SampleEvent(text: "first"))
        let e2 = EventData(eventType: "SampleEvent", model: SampleEvent(text: "second"))

        let revision = try await client.append(events: [e1, e2], toStream: "Order-1", category: "Order", expectedRevision: .noStream)
        #expect(revision == 1)

        let records = try await client.readStream(name: "Order-1", from: .start, resolveLinks: true)
        #expect(records.count == 2)
        #expect(records[0].revision == 0)
        #expect(records[1].revision == 1)
        #expect(try records[0].decode(to: SampleEvent.self) == SampleEvent(text: "first"))
        #expect(try records[1].decode(to: SampleEvent.self) == SampleEvent(text: "second"))
    }

    @Test("readStream(.specified) returns only events at/after the given revision")
    func readFromSpecifiedRevision() async throws {
        let client = InMemoryEventStoreClient()
        let events = (0..<3).map { EventData(eventType: "SampleEvent", model: SampleEvent(text: "\($0)")) }
        _ = try await client.append(events: events, toStream: "Order-1", category: "Order", expectedRevision: .noStream)

        let records = try await client.readStream(name: "Order-1", from: .specified(1), resolveLinks: true)
        #expect(records.map(\.revision) == [1, 2])
    }

    @Test("readStream throws streamNotFound for a stream that was never written")
    func readMissingStreamThrows() async throws {
        let client = InMemoryEventStoreClient()
        await #expect(throws: EventStoreClientError.streamNotFound) {
            _ = try await client.readStream(name: "Order-missing", from: .start, resolveLinks: true)
        }
    }

    @Test("readStream(.specified) past the end returns an empty array, not streamNotFound")
    func readPastEndReturnsEmptyNotNotFound() async throws {
        let client = InMemoryEventStoreClient()
        _ = try await client.append(
            events: [EventData(eventType: "SampleEvent", model: SampleEvent(text: "only"))],
            toStream: "Order-1",
            category: "Order",
            expectedRevision: .noStream
        )
        let records = try await client.readStream(name: "Order-1", from: .specified(5), resolveLinks: true)
        #expect(records.isEmpty)
    }

    @Test(".noStream append fails once the stream already has events")
    func noStreamConflictsOnceCreated() async throws {
        let client = InMemoryEventStoreClient()
        _ = try await client.append(
            events: [EventData(eventType: "SampleEvent", model: SampleEvent(text: "x"))],
            toStream: "Order-1",
            category: "Order",
            expectedRevision: .noStream
        )
        await #expect(throws: EventStoreClientError.self) {
            _ = try await client.append(
                events: [EventData(eventType: "SampleEvent", model: SampleEvent(text: "y"))],
                toStream: "Order-1",
                category: "Order",
                expectedRevision: .noStream
            )
        }
    }

    @Test(".at(revision) append fails on a stale revision")
    func atRevisionConflictsWhenStale() async throws {
        let client = InMemoryEventStoreClient()
        _ = try await client.append(
            events: [EventData(eventType: "SampleEvent", model: SampleEvent(text: "x"))],
            toStream: "Order-1",
            category: "Order",
            expectedRevision: .noStream
        )
        await #expect(throws: EventStoreClientError.self) {
            _ = try await client.append(
                events: [EventData(eventType: "SampleEvent", model: SampleEvent(text: "y"))],
                toStream: "Order-1",
                category: "Order",
                expectedRevision: .at(5)
            )
        }
    }

    @Test(".streamExists append fails when the stream doesn't exist yet")
    func streamExistsConflictsWhenAbsent() async throws {
        let client = InMemoryEventStoreClient()
        await #expect(throws: EventStoreClientError.self) {
            _ = try await client.append(
                events: [EventData(eventType: "SampleEvent", model: SampleEvent(text: "x"))],
                toStream: "Order-1",
                category: "Order",
                expectedRevision: .streamExists
            )
        }
    }

    @Test("deleteStream removes the stream; a subsequent read throws streamNotFound")
    func deleteStreamRemovesIt() async throws {
        let client = InMemoryEventStoreClient()
        _ = try await client.append(
            events: [EventData(eventType: "SampleEvent", model: SampleEvent(text: "x"))],
            toStream: "Order-1",
            category: "Order",
            expectedRevision: .noStream
        )
        try await client.deleteStream(name: "Order-1", expectedRevision: .streamExists)

        await #expect(throws: EventStoreClientError.streamNotFound) {
            _ = try await client.readStream(name: "Order-1", from: .start, resolveLinks: true)
        }
    }

    // The soft-delete tests below pin what KurrentDB 26.1.3 does (checked live): a deleted
    // stream reads as not found, keeps its tail, and a write recreates it from tail + 1.

    @Test("a stream deleted at revisions 0–2 and written again continues at 3, whether the write expects no stream, the old tail or any")
    func recreatedStreamContinuesFromOldTail() async throws {
        for expected in [StreamRevision.noStream, .at(2), .any] {
            let client = InMemoryEventStoreClient()
            _ = try await client.append(events: sampleEvents(3), toStream: "Order-1", category: "Order", expectedRevision: .noStream)
            try await client.deleteStream(name: "Order-1", expectedRevision: .any)

            let revision = try await client.append(events: sampleEvents(1), toStream: "Order-1", category: "Order", expectedRevision: expected)

            #expect(revision == 3, "expected \(expected)")
            #expect(try await client.readStream(name: "Order-1", from: .start, resolveLinks: true).map(\.revision) == [3])
        }
    }

    @Test("a write to a deleted stream expecting another revision conflicts with the old tail; expecting the stream to exist throws resourceDeleted")
    func deletedStreamRejectsOtherExpectations() async throws {
        let client = InMemoryEventStoreClient()
        _ = try await client.append(events: sampleEvents(3), toStream: "Order-1", category: "Order", expectedRevision: .noStream)
        try await client.deleteStream(name: "Order-1", expectedRevision: .at(2))

        for wrong in [UInt64(0), 5] {
            await #expect(throws: EventStoreClientError.wrongExpectedRevision(current: 2)) {
                _ = try await client.append(events: sampleEvents(1), toStream: "Order-1", category: "Order", expectedRevision: .at(wrong))
            }
        }
        await #expect(throws: KurrentError.self) {
            _ = try await client.append(events: sampleEvents(1), toStream: "Order-1", category: "Order", expectedRevision: .streamExists)
        }
        await #expect(throws: EventStoreClientError.streamNotFound) {
            _ = try await client.readStream(name: "Order-1", from: .start, resolveLinks: true)
        }
    }

    @Test("deleting a deleted stream again succeeds expecting any, the old tail or no stream, and throws resourceDeleted expecting it to exist")
    func deletingADeletedStream() async throws {
        let client = InMemoryEventStoreClient()
        _ = try await client.append(events: sampleEvents(2), toStream: "Order-1", category: "Order", expectedRevision: .noStream)
        try await client.deleteStream(name: "Order-1", expectedRevision: .at(1))

        try await client.deleteStream(name: "Order-1", expectedRevision: .any)
        try await client.deleteStream(name: "Order-1", expectedRevision: .at(1))
        try await client.deleteStream(name: "Order-1", expectedRevision: .noStream)
        await #expect(throws: KurrentError.self) {
            try await client.deleteStream(name: "Order-1", expectedRevision: .streamExists)
        }
        // Still recreated from the old tail.
        #expect(try await client.append(events: sampleEvents(1), toStream: "Order-1", category: "Order", expectedRevision: .noStream) == 2)
    }

    @Test("a resend of the batch that recreated a deleted stream returns its revision without writing again")
    func resendAfterRecreationIsIdempotent() async throws {
        let client = InMemoryEventStoreClient()
        _ = try await client.append(events: sampleEvents(3), toStream: "Order-1", category: "Order", expectedRevision: .noStream)
        try await client.deleteStream(name: "Order-1", expectedRevision: .any)
        let recreating = sampleEvents(2)
        #expect(try await client.append(events: recreating, toStream: "Order-1", category: "Order", expectedRevision: .at(2)) == 4)

        #expect(try await client.append(events: recreating, toStream: "Order-1", category: "Order", expectedRevision: .at(2)) == 4)
        #expect(try await client.readStream(name: "Order-1", from: .start, resolveLinks: true).map(\.revision) == [3, 4])
    }

    @Test("a stream name without a dash belongs to no category: $ce- subscriptions never get its events, as on a real cluster")
    func dashlessStreamIsNotCategorized() async throws {
        let client = InMemoryEventStoreClient()
        _ = try await client.append(events: sampleEvents(1), toStream: "Sales", category: "Sales", expectedRevision: .noStream)
        _ = try await client.append(events: sampleEvents(1), toStream: "Sales-1", category: "Sales", expectedRevision: .noStream)

        let session = try await client.subscribePersistent(stream: "$ce-Sales", group: "g")
        var iterator = session.events.makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first?.event.streamName == "Sales-1")

        // A live append to the dashless stream is not delivered either.
        _ = try await client.append(events: sampleEvents(1), toStream: "Sales", category: "Sales", expectedRevision: .at(0))
        _ = try await client.append(events: sampleEvents(1), toStream: "Sales-2", category: "Sales", expectedRevision: .noStream)
        let next = try await iterator.next()
        #expect(next?.event.streamName == "Sales-2")
    }

    @Test("a category with its own dash still routes by the stream name's first dash, matching real KurrentDB")
    func multiDashCategoryRoutesLikeRealKurrentDB() async throws {
        // Regression test: `EventStreamNaming.categoryRule` allows `.custom("Sales-Order")`,
        // giving stream names like `"Sales-Order-<id>"`. Real KurrentDB's `$by_category`
        // standard projection derives category from the stream name's segment up to its
        // *first* `-` server-side, regardless of what the appending client declares — so
        // `"Sales-Order-1"` lands under `$ce-Sales`, never `$ce-Sales-Order`. This fake must
        // reproduce that, or a test passing against it would give false confidence about a
        // subscription that never fires against a real cluster.
        let client = InMemoryEventStoreClient()
        _ = try await client.append(
            events: [EventData(eventType: "SampleEvent", model: SampleEvent(text: "x"))],
            toStream: "Sales-Order-1",
            category: "Sales-Order",
            expectedRevision: .noStream
        )

        let session = try await client.subscribePersistent(stream: "$ce-Sales", group: "g")
        var iterator = session.events.makeAsyncIterator()
        let delivery = try await iterator.next()
        #expect(delivery?.event.eventType == "SampleEvent")
    }

    @Test("subscribing to a $ce- stream whose category has its own dash throws unroutableCategory")
    func subscribingToDashedCategoryStreamThrows() async throws {
        // `$ce-Sales-Order` can never receive anything on a real cluster — no stream is
        // ever categorized under a name containing a dash. Failing at subscribe time beats
        // returning a session that silently never delivers (same rationale as
        // `unsupportedProjection` for `$et-`/`$all`).
        let client = InMemoryEventStoreClient()
        await #expect(throws: EventStoreClientError.unroutableCategory(stream: "$ce-Sales-Order")) {
            _ = try await client.subscribePersistent(stream: "$ce-Sales-Order", group: "g")
        }
    }
}
