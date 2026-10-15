import Testing
import Foundation
import KurrentDB
import KurrentSupport
import KurrentSupportInMemory

private struct Ping: Codable, Sendable { let n: Int }

private func append(_ client: InMemoryEventStoreClient, _ n: Int) async throws {
    _ = try await client.append(
        events: [EventData(eventType: "Ping", model: Ping(n: n))],
        toStream: "Ping-\(n)", category: "Ping", expectedRevision: .noStream
    )
}

private func first(_ session: any PersistentSubscriptionSession) async throws -> Int? {
    for try await delivery in session.events {
        return try delivery.event.decode(to: Ping.self)?.n
    }
    return nil
}

@Suite("InMemoryEventStoreClient — subscription groups")
struct InMemorySubscriptionGroupTests {

    @Test("requireExplicitGroups: subscribing to a missing group throws subscriptionGroupNotFound")
    func missingGroupThrows() async throws {
        let client = InMemoryEventStoreClient(requireExplicitGroups: true)
        await #expect(throws: EventStoreClientError.subscriptionGroupNotFound(stream: "$ce-Ping", group: "g")) {
            _ = try await client.subscribePersistent(stream: "$ce-Ping", group: "g")
        }
    }

    @Test("ensure is idempotent and startFrom .start replays history")
    func ensureStartReplays() async throws {
        let client = InMemoryEventStoreClient(requireExplicitGroups: true)
        try await append(client, 1)
        try await client.ensurePersistentSubscription(stream: "$ce-Ping", group: "g", settings: .init())
        try await client.ensurePersistentSubscription(stream: "$ce-Ping", group: "g", settings: .init())
        let session = try await client.subscribePersistent(stream: "$ce-Ping", group: "g")
        #expect(try await first(session) == 1)
    }

    @Test("startFrom .end skips history")
    func ensureEndSkipsHistory() async throws {
        let client = InMemoryEventStoreClient(requireExplicitGroups: true)
        try await append(client, 1)
        try await client.ensurePersistentSubscription(stream: "$ce-Ping", group: "g", settings: .init(startFrom: .end))
        let session = try await client.subscribePersistent(stream: "$ce-Ping", group: "g")
        try await append(client, 2)
        #expect(try await first(session) == 2)
    }

    @Test("delete ends live sessions with subscriptionGroupNotFound; deleting again is tolerated")
    func deleteEndsSessions() async throws {
        let client = InMemoryEventStoreClient(requireExplicitGroups: true)
        try await client.ensurePersistentSubscription(stream: "$ce-Ping", group: "g", settings: .init())
        let session = try await client.subscribePersistent(stream: "$ce-Ping", group: "g")
        try await client.deletePersistentSubscription(stream: "$ce-Ping", group: "g")
        try await client.deletePersistentSubscription(stream: "$ce-Ping", group: "g")
        #expect(await client.persistentSubscriptionExists(stream: "$ce-Ping", group: "g") == false)
        await #expect(throws: EventStoreClientError.subscriptionGroupNotFound(stream: "$ce-Ping", group: "g")) {
            _ = try await first(session)
        }
    }

    @Test("Default (requireExplicitGroups: false) still auto-creates on subscribe, replaying from start")
    func defaultAutoCreates() async throws {
        let client = InMemoryEventStoreClient()
        try await append(client, 1)
        let session = try await client.subscribePersistent(stream: "$ce-Ping", group: "g")
        #expect(try await first(session) == 1)
        #expect(await client.persistentSubscriptionExists(stream: "$ce-Ping", group: "g"))
    }
}
