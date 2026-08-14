#if os(Linux)
import ContextReceiver
import ContextReceiverWebSocket
import Logging
import Testing

/// Covers the Task 8 readiness ruling without a broker: `run()` is never
/// started, so the socket can never become ready, and `grantPermits` must
/// time out instead of hanging forever or throwing immediately. The
/// "throws immediately" alternative was ruled out because `ContextReceiver`
/// starts `source.run()` and its own permit grant as unordered sibling
/// tasks — throwing before the socket exists would fail startup almost
/// every time for a reason that has nothing to do with the broker.
@Suite("WebSocketMessageSource readiness")
struct WebSocketMessageSourceReadinessTests {
    @Test func grantPermitsTimesOutWithoutALiveSocket() async throws {
        let endpoint = ConsumerEndpoint(
            baseURL: "ws://127.0.0.1:1", tenant: "public", namespace: "default",
            topic: "unused", subscription: "unused"
        )
        let source = WebSocketMessageSource(
            endpoint: endpoint,
            readinessTimeout: .milliseconds(200),
            logger: Logger(label: "readiness-test")
        )

        do {
            try await source.grantPermits(1)
            Issue.record("expected grantPermits to time out with no live socket")
        } catch ReceiveError.transportUnavailable {
            // Expected: no socket ever arrives because `run()` was never called.
        }
    }
}
#endif
