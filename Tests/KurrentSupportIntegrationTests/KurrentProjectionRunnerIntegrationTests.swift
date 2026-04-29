import Testing
import Foundation
import KurrentDB
import KurrentSupport
import EventSourcing
import TestUtility
import Logging

@Suite("KurrentProjection.PersistentSubscriptionRunner — happy path", .serialized)
struct KurrentProjectionRunnerHappyPathTests {

    @Test("Runner dispatches event to all registered projectors and acks")
    func dispatchesAndAcks() async throws {
        let client = KurrentDBClient.makeIntegrationTestClient()
        let groupName = "test-runner-happy-\(UUID().uuidString.prefix(8))"
        let category = "RunnerHappyTest\(UUID().uuidString.prefix(6))"
        let stream = "$ce-\(category)"

        // Set up a persistent subscription on the `$ce-` category projection.
        // `resolveLink = true` so the subscription delivers the original
        // (resolved) recorded events rather than the link events that live in
        // the `$ce-` system stream — without this, `record.streamIdentifier`
        // would always be the `$ce-` stream itself.
        try await client.persistentSubscriptions(stream: stream, group: groupName).create { options in
            options.settings.resolveLink = true
        }
        defer {
            // Best-effort cleanup.
            Task { try? await client.persistentSubscriptions(stream: stream, group: groupName).delete() }
        }

        let aggregateId = UUID().uuidString
        let aggregateStream = "\(category)-\(aggregateId)"
        let payload = #"{"hello":"world"}"#.data(using: .utf8)!
        let eventData = try EventData(eventType: "TestEvent", payload: payload)
        _ = try await client.streams(of: .specified(aggregateStream)).append(events: eventData) { _ in }

        // Capture which inputs each registered closure received.
        let captured = LockedBox<[String]>([])
        let runner = KurrentProjection.PersistentSubscriptionRunner(
            client: client,
            stream: stream,
            groupName: groupName
        )
        .register(extractInput: { record -> String? in
            record.streamIdentifier.name
        }, execute: { (streamName: String) in
            captured.withLock { $0.append(streamName) }
        })

        // Run the runner in a background task; cancel as soon as the event is observed.
        let task = Task { try await runner.run() }

        // Poll up to 4 seconds for the event to arrive.
        let deadline = Date().addingTimeInterval(4.0)
        while Date() < deadline {
            if !captured.withLock({ $0.isEmpty }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        task.cancel()
        _ = try? await task.value

        let names = captured.withLock { $0 }
        #expect(names.contains(aggregateStream))
    }
}

// Tiny helper for thread-safe shared state in tests.
final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ initial: Value) { value = initial }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

@Suite("KurrentProjection.PersistentSubscriptionRunner — failure handling", .serialized)
struct KurrentProjectionRunnerFailureTests {

    private struct FailFirstNTimes: KurrentProjection.RetryPolicy, Sendable {
        // Test policy — surfaces the retry decision via NackAction.
        // Returns .retry up to 2 times, then .skip.
        func decide(error: any Error, retryCount: Int) -> KurrentProjection.NackAction {
            retryCount >= 2 ? .skip : .retry
        }
    }

    @Test("Failing projector triggers nack(.retry) until policy returns .skip")
    func failingProjectorRetriesAndSkips() async throws {
        let client = KurrentDBClient.makeIntegrationTestClient()
        let groupName = "test-runner-fail-\(UUID().uuidString.prefix(8))"
        let category = "RunnerFailTest\(UUID().uuidString.prefix(6))"
        let stream = "$ce-\(category)"

        try await client.persistentSubscriptions(stream: stream, group: groupName).create { options in
            options.settings.resolveLink = true
        }
        defer { Task { try? await client.persistentSubscriptions(stream: stream, group: groupName).delete() } }

        let aggregateStream = "\(category)-\(UUID().uuidString)"
        let payload = #"{}"#.data(using: .utf8)!
        let eventData = try EventData(eventType: "TestEvent", payload: payload)
        _ = try await client.streams(of: .specified(aggregateStream)).append(events: eventData) { _ in }

        struct AlwaysFails: Error {}

        let callCount = LockedBox(0)
        let runner = KurrentProjection.PersistentSubscriptionRunner(
            client: client,
            stream: stream,
            groupName: groupName,
            retryPolicy: FailFirstNTimes()
        )
        .register(extractInput: { _ -> Bool? in true }, execute: { _ in
            callCount.withLock { $0 += 1 }
            throw AlwaysFails()
        })

        let task = Task { try await runner.run() }

        // Poll up to 3 seconds for at least 3 retries (initial + 2 retries before policy says skip).
        // The tight deadline distinguishes nack-driven retry (sub-second per retry) from
        // KurrentDB's server-side message-timeout-driven retry (30+ seconds per retry).
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if callCount.withLock({ $0 }) >= 3 { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        task.cancel()
        _ = try? await task.value

        let count = callCount.withLock { $0 }
        #expect(count >= 3, "Expected at least 3 calls (initial + 2 retries), got \(count)")
    }
}

@Suite("KurrentProjection.PersistentSubscriptionRunner — .stop semantics", .serialized)
struct KurrentProjectionRunnerStopTests {

    private struct StopImmediatelyPolicy: KurrentProjection.RetryPolicy, Sendable {
        func decide(error: any Error, retryCount: Int) -> KurrentProjection.NackAction { .stop }
    }

    @Test("RetryPolicy returning .stop causes run() to throw RunnerStopped")
    func stopThrowsRunnerStopped() async throws {
        let client = KurrentDBClient.makeIntegrationTestClient()
        let groupName = "test-runner-stop-\(UUID().uuidString.prefix(8))"
        let category = "RunnerStopTest\(UUID().uuidString.prefix(6))"
        let stream = "$ce-\(category)"

        try await client.persistentSubscriptions(stream: stream, group: groupName).create { options in
            options.settings.resolveLink = true
        }
        defer { Task { try? await client.persistentSubscriptions(stream: stream, group: groupName).delete() } }

        let aggregateStream = "\(category)-\(UUID().uuidString)"
        let payload = #"{}"#.data(using: .utf8)!
        let eventData = try EventData(eventType: "TestEvent", payload: payload)
        _ = try await client.streams(of: .specified(aggregateStream)).append(events: eventData) { _ in }

        struct AlwaysFails: Error {}

        let runner = KurrentProjection.PersistentSubscriptionRunner(
            client: client,
            stream: stream,
            groupName: groupName,
            retryPolicy: StopImmediatelyPolicy()
        )
        .register(extractInput: { _ -> Bool? in true }, execute: { _ in throw AlwaysFails() })

        await #expect(throws: KurrentProjection.RunnerStopped.self) {
            try await runner.run()
        }
    }
}

@Suite("KurrentProjection.PersistentSubscriptionRunner — cancellation", .serialized)
struct KurrentProjectionRunnerCancellationTests {

    @Test("External Task.cancel() returns normally without throwing")
    func cancelReturnsNormally() async throws {
        let client = KurrentDBClient.makeIntegrationTestClient()
        let groupName = "test-runner-cancel-\(UUID().uuidString.prefix(8))"
        let category = "RunnerCancelTest\(UUID().uuidString.prefix(6))"
        let stream = "$ce-\(category)"

        try await client.persistentSubscriptions(stream: stream, group: groupName).create { options in
            options.settings.resolveLink = true
        }
        defer { Task { try? await client.persistentSubscriptions(stream: stream, group: groupName).delete() } }

        let runner = KurrentProjection.PersistentSubscriptionRunner(
            client: client,
            stream: stream,
            groupName: groupName
        )

        let task = Task { try await runner.run() }
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()

        // run() should complete without throwing.
        // .value will rethrow if the task threw.
        _ = try await task.value
    }
}

@Suite("KurrentProjection.PersistentSubscriptionRunner — subscription failure", .serialized)
struct KurrentProjectionRunnerSubscriptionFailureTests {

    @Test("subscribe() failure (group does not exist) throws out of run()")
    func subscribeFailureThrows() async throws {
        let client = KurrentDBClient.makeIntegrationTestClient()
        let nonExistentGroup = "definitely-not-a-real-group-\(UUID().uuidString)"
        let stream = "$ce-NoSuchCategory\(UUID().uuidString.prefix(6))"

        let runner = KurrentProjection.PersistentSubscriptionRunner(
            client: client,
            stream: stream,
            groupName: nonExistentGroup
        )

        // Calling run() without first creating the persistent subscription should throw.
        await #expect(throws: (any Error).self) {
            try await runner.run()
        }
    }
}

@Suite("KurrentProjection.PersistentSubscriptionRunner — eventFilter integration", .serialized)
struct KurrentProjectionRunnerEventFilterTests {

    private struct OnlyEventA: EventTypeFilter {
        func handles(eventType: String) -> Bool { eventType == "EventA" }
    }
    private struct OnlyEventB: EventTypeFilter {
        func handles(eventType: String) -> Bool { eventType == "EventB" }
    }

    @Test("eventFilter pre-filters events by type — only matching projector fires")
    func filterRoutesToCorrectProjectorOnly() async throws {
        let client = KurrentDBClient.makeIntegrationTestClient()
        let groupName = "test-runner-filter-\(UUID().uuidString.prefix(8))"
        let category = "RunnerFilterTest\(UUID().uuidString.prefix(6))"
        let stream = "$ce-\(category)"

        try await client.persistentSubscriptions(stream: stream, group: groupName).create { options in
            options.settings.resolveLink = true
        }
        defer { Task { try? await client.persistentSubscriptions(stream: stream, group: groupName).delete() } }

        let aggregateStream = "\(category)-\(UUID().uuidString)"
        // Append two events of different types
        for eventType in ["EventA", "EventB"] {
            let payload = #"{}"#.data(using: .utf8)!
            let eventData = try EventData(eventType: eventType, payload: payload)
            _ = try await client.streams(of: .specified(aggregateStream))
                .append(events: eventData) { _ in }
        }

        let aCalls = LockedBox(0)
        let bCalls = LockedBox(0)

        let runner = KurrentProjection.PersistentSubscriptionRunner(
            client: client,
            stream: stream,
            groupName: groupName
        )
        .register(
            eventFilter: OnlyEventA(),
            extractInput: { _ -> Bool? in true },
            execute: { _ in aCalls.withLock { $0 += 1 } }
        )
        .register(
            eventFilter: OnlyEventB(),
            extractInput: { _ -> Bool? in true },
            execute: { _ in bCalls.withLock { $0 += 1 } }
        )

        let task = Task { try await runner.run() }

        // Poll up to 4 seconds for both projectors to receive their respective event.
        let deadline = Date().addingTimeInterval(4.0)
        while Date() < deadline {
            if aCalls.withLock({ $0 }) >= 1 && bCalls.withLock({ $0 }) >= 1 { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        task.cancel()
        _ = try? await task.value

        let a = aCalls.withLock { $0 }
        let b = bCalls.withLock { $0 }

        // Each projector saw exactly one event (its own type).
        // Without filter, both would have seen 2 events each.
        #expect(a == 1, "OnlyEventA registration was called \(a) times; expected exactly 1")
        #expect(b == 1, "OnlyEventB registration was called \(b) times; expected exactly 1")
    }
}
