#if os(Linux)
import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import Testing
import PublishedLanguage
import ContextReceiver
import ContextReceiverWebSocket
@testable import ContextForwarder

/// Gated on PULSAR_HTTP_URL so the default `swift test` stays offline, matching
/// the project's existing integration-test convention.
///
/// This is the only test in the whole plan that proves the produce/consume
/// payload asymmetry end to end: `PulsarRESTPublisher` sends a raw JSON
/// string, Pulsar's WebSocket consumer hands it back base64-encoded, and
/// `ConsumerFrame.decodedEvent()` undoes that. Every other test either
/// builds the REST body by hand (produce side) or feeds hand-built
/// base64 into the decoder (consume side) — neither side has ever been
/// checked against what the other actually does until this test runs
/// against a real broker.
@Suite("Live Pulsar round trip", .enabled(if: ProcessInfo.processInfo.environment["PULSAR_HTTP_URL"] != nil))
struct LivePulsarTests {
    private var httpURL: String { ProcessInfo.processInfo.environment["PULSAR_HTTP_URL"]! }
    private var wsURL: String {
        ProcessInfo.processInfo.environment["PULSAR_WS_URL"]
            ?? httpURL.replacingOccurrences(of: "http://", with: "ws://")
    }

    private actor Collector: PublishedLanguageHandler {
        private(set) var received: [ReceivedRecord] = []
        func handle(_ record: ReceivedRecord) async throws { received.append(record) }
        func waitForCount(_ count: Int, timeout: Duration) async throws -> Bool {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline {
                if received.count >= count { return true }
                try await Task.sleep(for: .milliseconds(100))
            }
            return false
        }
    }

    /// Proves the produce/consume payload asymmetry is handled: the forwarder
    /// sends a raw JSON string, the broker hands it back base64-encoded, and
    /// the event survives the trip intact.
    @Test func forwarderPublishesAndReceiverConsumes() async throws {
        let logger = Logger(label: "live")
        let topic = "ctxrecv-itest-\(UUID().uuidString.prefix(8))"
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        // `HTTPClient.syncShutdown()` is `noasync` — it cannot be called from
        // this test's async context even inside `defer`, and `defer` bodies
        // cannot themselves `await`. So both the success and failure paths
        // shut the client down explicitly with the async API instead.
        do {
            try await runRoundTrip(httpClient: httpClient, topic: topic, logger: logger)
        } catch {
            try? await httpClient.shutdown()
            throw error
        }
        try? await httpClient.shutdown()
    }

    private func runRoundTrip(httpClient: HTTPClient, topic: String, logger: Logger) async throws {
        let endpoint = ConsumerEndpoint(
            baseURL: wsURL, tenant: "public", namespace: "default",
            topic: topic, subscription: "itest"
        )
        let source = WebSocketMessageSource(endpoint: endpoint, logger: logger)
        let collector = Collector()
        let receiver = ContextReceiver(source: source, handler: collector, logger: logger)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await source.run() }
            group.addTask { try await receiver.run() }

            // Let the subscription attach before producing, otherwise the
            // message lands before the cursor exists. `receiver.run()`'s
            // initial permit grant now waits (bounded) for `source.run()`'s
            // socket to come up, so this sleep only needs to cover the
            // broker-side subscribe, not our own connect race.
            try await Task.sleep(for: .seconds(3))

            let event = PublishedLanguageEvent(
                eventId: "e-live-1",
                eventType: "ItestEvent.v1",
                occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
                recipientIds: ["u-1"],
                payload: ["opportunityId": "o-1"],
                partitionKey: "opportunity-123"
            )

            var request = HTTPClientRequest(
                url: "\(httpURL)/topics/persistent/public/default/\(topic)"
            )
            request.method = .POST
            request.headers.add(name: "Content-Type", value: "application/json")
            request.body = .bytes(ByteBuffer(bytes: try PulsarRESTPublisher.produceBody(for: event)))
            let response = try await httpClient.execute(request, timeout: .seconds(15))
            #expect(response.status.code < 300, "produce failed with \(response.status)")

            #expect(try await collector.waitForCount(1, timeout: .seconds(30)))
            let record = await collector.received.first
            #expect(record?.event.eventId == "e-live-1")
            #expect(record?.event.payload["opportunityId"] == "o-1")
            #expect(record?.key == "opportunity-123", "partition key must survive the round trip")
            #expect(record?.redeliveryCount == 0)

            group.cancelAll()
        }
    }
}
#endif
