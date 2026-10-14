import Testing
import Foundation
import KurrentDB
import EventSourcing
import ReadModelPersistence
import KurrentSupport
import KurrentSupportInMemory

private struct Summary: ReadModel, Sendable { let id: String }
private struct Ping: Codable, Sendable { let n: Int }

@Suite("KurrentProjection.rebuild")
struct RebuildTests {

    private func seeded() async throws -> (InMemoryEventStoreClient, InMemoryReadModelStore<Summary>) {
        let client = InMemoryEventStoreClient(requireExplicitGroups: true)
        _ = try await client.append(
            events: [EventData(eventType: "Ping", model: Ping(n: 1))],
            toStream: "Ping-1", category: "Ping", expectedRevision: .noStream
        )
        try await client.ensurePersistentSubscription(stream: "$ce-Ping", group: "g", settings: .init(startFrom: .end))
        let store = InMemoryReadModelStore<Summary>()
        try await store.save(readModel: Summary(id: "1"), revision: 0)
        return (client, store)
    }

    @Test("Purges snapshots and recreates the group from the start")
    func purgesAndResets() async throws {
        let (client, store) = try await seeded()

        try await KurrentProjection.rebuild(
            readModels: [Summary.self], snapshots: store,
            eventStore: client, stream: "$ce-Ping", group: "g"
        )

        #expect(try await store.fetch(byId: "1") == nil)
        let session = try await client.subscribePersistent(stream: "$ce-Ping", group: "g")
        var replayed: Int?
        for try await delivery in session.events {
            replayed = try delivery.event.decode(to: Ping.self)?.n
            break
        }
        #expect(replayed == 1) // the old group started at .end; the rebuilt one replays history
    }

    @Test("Rebuilding twice in a row (a re-run after a partial failure) succeeds")
    func idempotent() async throws {
        let (client, store) = try await seeded()
        for _ in 0..<2 {
            try await KurrentProjection.rebuild(
                readModels: [Summary.self], snapshots: store,
                eventStore: client, stream: "$ce-Ping", group: "g"
            )
        }
        #expect(await client.persistentSubscriptionExists(stream: "$ce-Ping", group: "g"))
    }

    @Test("Works when the group never existed")
    func missingGroup() async throws {
        let client = InMemoryEventStoreClient(requireExplicitGroups: true)
        try await KurrentProjection.rebuild(
            readModels: [Summary.self], snapshots: InMemoryReadModelStore<Summary>(),
            eventStore: client, stream: "$ce-Ping", group: "g"
        )
        #expect(await client.persistentSubscriptionExists(stream: "$ce-Ping", group: "g"))
    }
}
