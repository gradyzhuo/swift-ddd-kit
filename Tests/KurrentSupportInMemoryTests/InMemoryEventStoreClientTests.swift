import Testing
import Foundation
import KurrentDB
import KurrentSupport
import KurrentSupportInMemory

private struct SampleEvent: Codable, Sendable, Equatable {
    let text: String
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

    @Test("category with its own dash is passed through, not re-derived from the stream name")
    func multiDashCategoryIsNotMisparsed() async throws {
        // Regression test: `EventStreamNaming.categoryRule` allows `.custom("Sales-Order")`,
        // giving stream names like `"Sales-Order-<id>"`. A naive "split on the first dash"
        // would derive category `"Sales"` here — wrong, and inconsistent with what a
        // `$ce-Sales-Order` subscriber asks for. `category` must be taken from the caller,
        // not guessed from `toStream`.
        let client = InMemoryEventStoreClient()
        _ = try await client.append(
            events: [EventData(eventType: "SampleEvent", model: SampleEvent(text: "x"))],
            toStream: "Sales-Order-1",
            category: "Sales-Order",
            expectedRevision: .noStream
        )

        let session = try await client.subscribePersistent(stream: "$ce-Sales-Order", group: "g")
        var iterator = session.events.makeAsyncIterator()
        let delivery = try await iterator.next()
        #expect(delivery?.event.eventType == "SampleEvent")
    }
}
