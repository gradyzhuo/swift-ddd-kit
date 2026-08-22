import Testing
import Foundation
import Synchronization
import KurrentDB
import KurrentSupport
import KurrentSupportInMemory

private struct OrderCreated: Codable, Sendable, Equatable {
    let orderId: String
}

/// Bounded polling helper — the point of `InMemoryEventStoreClient` is that
/// production code needs no sleeps, but a *test* observing a background
/// `Task`-driven runner still needs to wait for that task to get scheduled.
private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("condition not met within \(timeout)")
}

@Suite("InMemoryEventStoreClient — persistent subscription push")
struct InMemoryPersistentSubscriptionTests {

    @Test("PersistentSubscriptionRunner replays an already-appended event via \\$ce category routing, no live KurrentDB")
    func replaysAlreadyAppendedEventOnSubscribe() async throws {
        let client = InMemoryEventStoreClient()
        _ = try await client.append(
            events: [EventData(eventType: "OrderCreated", model: OrderCreated(orderId: "order-1"))],
            toStream: "Order-order-1",
            category: "Order",
            expectedRevision: .noStream
        )

        let runner = KurrentProjection.PersistentSubscriptionRunner(
            client: client,
            stream: "$ce-Order",
            groupName: "test-group"
        )

        let processed = Mutex<[String]>([])
        runner.register(
            extractInput: { record in record.eventType },
            execute: { eventType in
                processed.withLock { $0.append(eventType) }
            }
        )

        let runTask = Task { try await runner.run() }
        try await waitUntil { processed.withLock { $0.count } == 1 }
        runTask.cancel()

        #expect(processed.withLock { $0 } == ["OrderCreated"])
    }

    @Test("PersistentSubscriptionRunner picks up an event appended after the runner has started")
    func picksUpLiveAppendAfterSubscribing() async throws {
        let client = InMemoryEventStoreClient()
        let runner = KurrentProjection.PersistentSubscriptionRunner(
            client: client,
            stream: "$ce-Order",
            groupName: "test-group"
        )

        let processed = Mutex<[String]>([])
        runner.register(
            extractInput: { record in try? record.decode(to: OrderCreated.self)?.orderId },
            execute: { orderId in
                processed.withLock { $0.append(orderId) }
            }
        )

        let runTask = Task { try await runner.run() }

        _ = try await client.append(
            events: [EventData(eventType: "OrderCreated", model: OrderCreated(orderId: "order-2"))],
            toStream: "Order-order-2",
            category: "Order",
            expectedRevision: .noStream
        )

        try await waitUntil { processed.withLock { $0.count } == 1 }
        runTask.cancel()

        #expect(processed.withLock { $0 } == ["order-2"])
    }

    @Test("A throwing registration causes a nack; MaxRetriesPolicy stops retrying and the event is redelivered until skipped")
    func nackRetryRedeliversUntilSkip() async throws {
        let client = InMemoryEventStoreClient()
        _ = try await client.append(
            events: [EventData(eventType: "OrderCreated", model: OrderCreated(orderId: "order-3"))],
            toStream: "Order-order-3",
            category: "Order",
            expectedRevision: .noStream
        )

        let runner = KurrentProjection.PersistentSubscriptionRunner(
            client: client,
            stream: "$ce-Order",
            groupName: "test-group",
            retryPolicy: KurrentProjection.MaxRetriesPolicy(max: 2)
        )

        let attempts = Mutex<Int>(0)
        struct AlwaysFails: Error {}
        runner.register(
            extractInput: { record in record.eventType },
            execute: { _ in
                attempts.withLock { $0 += 1 }
                throw AlwaysFails()
            }
        )

        let runTask = Task { try await runner.run() }
        // MaxRetriesPolicy(max: 2): retryCount 0 -> .retry, 1 -> .retry, 2 -> .skip.
        // So the event is delivered 3 times total before being skipped.
        try await waitUntil(timeout: .seconds(3)) { attempts.withLock { $0 } == 3 }
        runTask.cancel()

        #expect(attempts.withLock { $0 } == 3)
    }

    @Test("subscribePersistent throws for a system-projection stream this fake doesn't emulate, instead of hanging forever")
    func unsupportedSystemProjectionThrows() async throws {
        // Only `$ce-<Category>` is emulated. `$et-<EventType>` (by-event-type), `$all`,
        // and friends previously fell through to "a normal, never-written-to stream" —
        // the subscription would succeed but never receive anything, with no error.
        let client = InMemoryEventStoreClient()
        await #expect(throws: EventStoreClientError.unsupportedProjection(stream: "$et-OrderCreated")) {
            _ = try await client.subscribePersistent(stream: "$et-OrderCreated", group: "g")
        }
    }
}
