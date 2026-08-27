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
        // cannot themselves `await`. So every exit path shuts the client
        // down explicitly with the async API instead, after best-effort
        // deleting the scratch topic this test created on the shared broker.
        do {
            try await runRoundTrip(httpClient: httpClient, topic: topic, logger: logger)
        } catch {
            await deleteTopicBestEffort(httpClient: httpClient, topic: topic)
            try? await httpClient.shutdown()
            throw error
        }
        await deleteTopicBestEffort(httpClient: httpClient, topic: topic)
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

            // Let the subscription actually attach before producing —
            // otherwise the message lands before the cursor exists and is
            // never delivered. `receiver.run()`'s initial permit grant now
            // waits (bounded) for `source.run()`'s socket to come up, but
            // that only covers *our* connect race, not the broker attaching
            // the subscription server-side, so this polls the admin API
            // rather than sleeping blind for a guessed duration.
            try await waitForSubscriptionAttached(httpClient: httpClient, topic: topic, timeout: .seconds(15))

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
            // `#require`, not `#expect`: a 4xx here (e.g. the missing
            // `valueSchema` the plan called out) must fail at the actual
            // cause immediately, not fall through into a 30-second consume
            // wait that reports "waitForCount was false" next to an error
            // that already explained itself.
            try #require(response.status.code < 300, "produce failed with \(response.status)")

            #expect(try await collector.waitForCount(1, timeout: .seconds(30)))
            let record = await collector.received.first
            #expect(record?.event.eventId == "e-live-1")
            #expect(record?.event.payload["opportunityId"] == "o-1")
            #expect(record?.key == "opportunity-123", "partition key must survive the round trip")
            #expect(record?.redeliveryCount == 0)

            group.cancelAll()
            // `cancelAll` does not itself wait for the children to observe
            // cancellation. Draining here means a `source.run()`/`receiver.run()`
            // that surfaced a real error after cancellation would fail this
            // test loudly and immediately, instead of relying on
            // `withThrowingTaskGroup` silently discarding a cancelled
            // child's error on scope exit — which happens to be true today
            // but is not a documented guarantee.
            while !group.isEmpty {
                _ = try? await group.next()
            }
        }
    }

    /// Polls Pulsar's topic stats admin endpoint until the `itest`
    /// subscription appears, rather than sleeping a guessed duration.
    /// Mirrors the plan's own broker-readiness pattern ("wait for readiness
    /// rather than sleeping blind") applied one level deeper, to the
    /// subscription instead of the broker.
    private func waitForSubscriptionAttached(
        httpClient: HTTPClient, topic: String, timeout: Duration
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            var request = HTTPClientRequest(
                url: "\(httpURL)/admin/v2/persistent/public/default/\(topic)/stats"
            )
            request.method = .GET
            if let response = try? await httpClient.execute(request, timeout: .seconds(5)),
               response.status.code == 200,
               let bodyBuffer = try? await response.body.collect(upTo: 1 << 20) {
                let json = try? JSONSerialization.jsonObject(with: Data(String(buffer: bodyBuffer).utf8))
                if let stats = json as? [String: Any],
                   let subscriptions = stats["subscriptions"] as? [String: Any],
                   subscriptions["itest"] != nil {
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw SubscriptionNeverAttached(topic: topic, timeout: timeout)
    }

    /// Best-effort: this test writes a uniquely-named scratch topic into
    /// whatever broker `PULSAR_HTTP_URL` points at (a long-lived shared
    /// broker in practice), and nothing else reclaims it. A failed delete
    /// must never fail the test — cleanup is a courtesy, not part of the
    /// thing under test.
    private func deleteTopicBestEffort(httpClient: HTTPClient, topic: String) async {
        var request = HTTPClientRequest(
            url: "\(httpURL)/admin/v2/persistent/public/default/\(topic)?force=true"
        )
        request.method = .DELETE
        _ = try? await httpClient.execute(request, timeout: .seconds(10))
    }
}

private struct SubscriptionNeverAttached: Error, CustomStringConvertible {
    let topic: String
    let timeout: Duration
    var description: String {
        "subscription 'itest' never attached to topic \(topic) within \(timeout)"
    }
}
#endif
