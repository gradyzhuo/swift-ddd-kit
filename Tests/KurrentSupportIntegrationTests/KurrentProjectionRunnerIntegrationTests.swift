import Testing
import Foundation
import KurrentDB
import KurrentSupport
import TestUtility
import Logging

@Suite("KurrentProjection.PersistentSubscriptionRunner — happy path", .serialized)
struct KurrentProjectionRunnerHappyPathTests {

    private static func makeClient() -> KurrentDBClient {
        // The plan was written for an insecure single-node setup, but the
        // running environment is a 3-node TLS-secured cluster (kurrentdb 26.0)
        // exposed on localhost ports 2111/2112/2113. Use seed-cluster discovery
        // with TLS verification disabled (self-signed dev certs).
        let settings = ClientSettings(
            clusterMode: .seeds([
                .init(host: "localhost", port: 2111),
                .init(host: "localhost", port: 2112),
                .init(host: "localhost", port: 2113),
            ]),
            secure: true,
            tlsVerifyCert: false
        ).authenticated(.credentials(username: "admin", password: "changeit"))
        return KurrentDBClient(settings: settings)
    }

    @Test("Runner dispatches event to all registered projectors and acks")
    func dispatchesAndAcks() async throws {
        let client = Self.makeClient()
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

        // Run the runner in a background task; cancel after a short window.
        let task = Task { try await runner.run() }
        try await Task.sleep(for: .seconds(2))
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
