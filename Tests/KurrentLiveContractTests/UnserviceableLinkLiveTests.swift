import Testing
import Foundation
import EventSourcing
import EventStoreContract
import KurrentDB
import KurrentSupport
import TestUtility

// Reading a stream of links (`$>` events, as a `linkTo` projection writes) whose targets
// are gone: deleted, tombstoned or truncated away. KurrentDB then returns the link without
// its event. The read skips such links and keeps the rest. Every test writes streams of
// fresh ids, so reruns and tests running in parallel never meet.

private struct LinkedEvent: Codable, Sendable {
    let text: String
}

private func linkedEvent(_ text: String) -> EventData {
    EventData(eventType: "LinkedEvent", model: LinkedEvent(text: text))
}

/// A `$>` link to `revision` of `stream`.
private func link(to stream: String, revision: UInt64) -> EventData {
    EventData(eventType: "$>", data: Data("\(revision)@\(stream)".utf8), contentType: .binary)
}

private func texts(_ records: [any RecordedEventLike]) throws -> [String] {
    try records.map { try #require(try $0.decode(to: LinkedEvent.self)).text }
}

@Suite("Live KurrentDB: links whose target is gone")
struct UnserviceableLinkLiveTests {

    @Test("links into a tombstoned stream are skipped; the rest of the stream is read")
    func tombstonedTarget() async throws {
        try await KurrentDBClient.withPooledIntegrationTestClient { client in
            let live = LiveEventStoreClient(client: client)
            let source = "LinkSource-\(UUID().uuidString)"
            let other = "LinkSource-\(UUID().uuidString)"
            let links = "LinkList-\(UUID().uuidString)"

            _ = try await live.append(events: [linkedEvent("gone 0"), linkedEvent("gone 1")], toStream: source, category: "LinkSource", expectedRevision: .noStream)
            _ = try await live.append(events: [linkedEvent("kept")], toStream: other, category: "LinkSource", expectedRevision: .noStream)
            _ = try await live.append(
                events: [link(to: source, revision: 0), link(to: other, revision: 0), link(to: source, revision: 1), linkedEvent("own")],
                toStream: links,
                category: "LinkList",
                expectedRevision: .noStream
            )
            try await live.tombstoneStream(name: source)

            let records = try await live.readStream(name: links, from: .start, resolveLinks: true)

            #expect(try texts(records) == ["kept", "own"])
        }
    }

    @Test("a link to a truncated event is skipped; a link to a later event of that stream still resolves")
    func truncatedTarget() async throws {
        try await KurrentDBClient.withPooledIntegrationTestClient { client in
            let live = LiveEventStoreClient(client: client)
            let source = "LinkSource-\(UUID().uuidString)"
            let links = "LinkList-\(UUID().uuidString)"

            _ = try await live.append(events: [linkedEvent("truncated"), linkedEvent("kept")], toStream: source, category: "LinkSource", expectedRevision: .noStream)
            _ = try await live.append(
                events: [link(to: source, revision: 0), link(to: source, revision: 1)],
                toStream: links,
                category: "LinkList",
                expectedRevision: .noStream
            )
            try await client.streams(specified: source).setMetadata(metadata: StreamMetadata().truncateBefore(1))

            let records = try await live.readStream(name: links, from: .start, resolveLinks: true)

            #expect(try texts(records) == ["kept"])
        }
    }

    @Test("a stream holding only dead links reads as empty, not as a missing stream")
    func onlyDeadLinks() async throws {
        try await KurrentDBClient.withPooledIntegrationTestClient { client in
            let live = LiveEventStoreClient(client: client)
            let source = "LinkSource-\(UUID().uuidString)"
            let links = "LinkList-\(UUID().uuidString)"

            _ = try await live.append(events: [linkedEvent("gone")], toStream: source, category: "LinkSource", expectedRevision: .noStream)
            _ = try await live.append(events: [link(to: source, revision: 0)], toStream: links, category: "LinkList", expectedRevision: .noStream)
            try await live.tombstoneStream(name: source)

            let records = try await live.readStream(name: links, from: .start, resolveLinks: true)

            #expect(records.isEmpty)
        }
    }

    @Test("KurrentStorageCoordinator.fetchEvents returns the events whose links still resolve")
    func coordinatorFetch() async throws {
        try await KurrentDBClient.withPooledIntegrationTestClient { client in
            let live = LiveEventStoreClient(client: client)
            let id = UUID().uuidString
            let gone = "LinkSource-\(UUID().uuidString)"
            let kept = "LinkSource-\(UUID().uuidString)"

            _ = try await live.append(
                events: [EventData(eventType: "ContractEvent", model: ContractEvent(aggregateRootId: id, value: 1))],
                toStream: gone,
                category: "LinkSource",
                expectedRevision: .noStream
            )
            _ = try await live.append(
                events: [EventData(eventType: "ContractEvent", model: ContractEvent(aggregateRootId: id, value: 2))],
                toStream: kept,
                category: "LinkSource",
                expectedRevision: .noStream
            )
            _ = try await live.append(
                events: [link(to: gone, revision: 0), link(to: kept, revision: 0)],
                toStream: ContractStream.getStreamName(id: id),
                category: ContractStream.category,
                expectedRevision: .noStream
            )
            try await live.tombstoneStream(name: gone)

            let store = KurrentStorageCoordinator<ContractStream, ContractMetadata>(client: client, eventMapper: ContractEventMapper())
            let fetched = try await store.fetchEvents(byId: id)

            #expect(fetched?.events.compactMap { ($0 as? ContractEvent)?.value } == [2])
        }
    }
}
