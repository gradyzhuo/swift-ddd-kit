import Testing
import Foundation
import Synchronization
import KurrentDB
import EventSourcing
import KurrentSupport
import KurrentSupportInMemory

private final class Seen: Sendable {
    private let values = Mutex<[Int]>([])
    func withLock<R: Sendable>(_ body: (inout [Int]) -> R) -> R { values.withLock { body(&$0) } }
}

private struct Ping: Codable, Sendable { let n: Int }

private func append(_ client: InMemoryEventStoreClient, _ n: Int) async throws {
    _ = try await client.append(
        events: [EventData(eventType: "Ping", model: Ping(n: n))],
        toStream: "Ping-\(n)", category: "Ping", expectedRevision: .noStream
    )
}

private func waitUntil(timeout: Duration = .seconds(2), _ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("condition not met within \(timeout)")
}

private func makeRunner(
    _ client: InMemoryEventStoreClient,
    setup: KurrentProjection.SubscriptionSetup = .ensure(.init()),
    into seen: Seen
) -> KurrentProjection.PersistentSubscriptionRunner {
    KurrentProjection.PersistentSubscriptionRunner(
        client: client, stream: "$ce-Ping", groupName: "g", subscriptionSetup: setup
    )
    .register(
        extractInput: { try? $0.decode(to: Ping.self)?.n },
        execute: { n in seen.withLock { $0.append(n) } }
    )
}

@Suite("Runner subscription setup")
struct RunnerSubscriptionSetupTests {

    @Test(".ensure (default) creates a missing group from the start and consumes history")
    func ensureCreatesGroup() async throws {
        let client = InMemoryEventStoreClient(requireExplicitGroups: true)
        try await append(client, 1)
        let seen = Seen()
        let run = Task { try await makeRunner(client, into: seen).run() }
        try await waitUntil { seen.withLock { $0 } == [1] }
        run.cancel()
        #expect(await client.persistentSubscriptionExists(stream: "$ce-Ping", group: "g"))
    }

    @Test(".ensure(startFrom: .end) does not replay history")
    func ensureFromEnd() async throws {
        let client = InMemoryEventStoreClient(requireExplicitGroups: true)
        try await append(client, 1)
        let seen = Seen()
        let run = Task { try await makeRunner(client, setup: .ensure(.init(startFrom: .end)), into: seen).run() }
        try await waitUntil { await client.persistentSubscriptionExists(stream: "$ce-Ping", group: "g") }
        try await append(client, 2)
        try await waitUntil { !seen.withLock { $0 }.isEmpty }
        run.cancel()
        #expect(seen.withLock { $0 } == [2])
    }

    @Test("Group deleted mid-run: run throws subscriptionGroupNotFound, group is recreated, a rerun resumes from the start")
    func recreatesDeletedGroup() async throws {
        let client = InMemoryEventStoreClient(requireExplicitGroups: true)
        try await append(client, 1)
        let seen = Seen()
        let runner = makeRunner(client, into: seen)

        let first = Task { try await runner.run() }
        try await waitUntil { seen.withLock { $0 } == [1] }
        try await client.deletePersistentSubscription(stream: "$ce-Ping", group: "g")

        await #expect(throws: EventStoreClientError.subscriptionGroupNotFound(stream: "$ce-Ping", group: "g")) {
            try await first.value
        }
        #expect(await client.persistentSubscriptionExists(stream: "$ce-Ping", group: "g"))

        let second = Task { try await runner.run() }
        try await append(client, 2)
        try await waitUntil { seen.withLock { $0 }.contains(2) }
        second.cancel()
        // Replayed from the start after recreation: 1 is seen again, then 2.
        #expect(seen.withLock { $0 } == [1, 1, 2])
    }

    @Test(".manual keeps the old behavior: a missing group is an error and is not created")
    func manualDoesNotCreate() async throws {
        let client = InMemoryEventStoreClient(requireExplicitGroups: true)
        let seen = Seen()
        await #expect(throws: EventStoreClientError.subscriptionGroupNotFound(stream: "$ce-Ping", group: "g")) {
            try await makeRunner(client, setup: .manual, into: seen).run()
        }
        #expect(await client.persistentSubscriptionExists(stream: "$ce-Ping", group: "g") == false)
    }

    @Test("TransactionalSubscriptionRunner also ensures its group")
    func transactionalEnsures() async throws {
        let client = InMemoryEventStoreClient(requireExplicitGroups: true)
        let runner = KurrentProjection.TransactionalSubscriptionRunner(
            client: client, transactionProvider: NoopProvider(), stream: "$ce-Ping", groupName: "g"
        )
        let run = Task { try await runner.run() }
        try await waitUntil { await client.persistentSubscriptionExists(stream: "$ce-Ping", group: "g") }
        run.cancel()
    }
}

struct NoopProvider: TransactionProvider {
    typealias Transaction = Int
    func withTransaction<Result: Sendable>(_ body: (Int) async throws -> Result) async throws -> Result {
        try await body(0)
    }
}
