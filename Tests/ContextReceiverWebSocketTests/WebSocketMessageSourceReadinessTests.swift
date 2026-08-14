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
        let timeout: Duration = .milliseconds(200)
        let source = WebSocketMessageSource(
            endpoint: endpoint,
            readinessTimeout: timeout,
            logger: Logger(label: "readiness-test")
        )

        let started = ContinuousClock.now
        do {
            try await source.grantPermits(1)
            Issue.record("expected grantPermits to time out with no live socket")
        } catch ReceiveError.transportUnavailable(let message) {
            // Both assertions are required, not just one: the pre-fix code
            // threw this exact case — `ReceiveError.transportUnavailable`
            // from `send`'s `guard let outbound` — immediately, with the
            // message "socket not connected". Matching only the case would
            // pass against that reverted behaviour too. Elapsed time proves
            // this actually *waited* rather than failing fast, and the
            // message wording proves it came from `waitForSocketReady`
            // specifically, not from `send`.
            let elapsed = started.duration(to: .now)
            #expect(
                elapsed >= .milliseconds(150),
                "expected grantPermits to wait close to the \(timeout) readiness timeout, took \(elapsed)"
            )
            #expect(
                message.contains("became ready within"),
                "expected the readiness-timeout message, got: \(message)"
            )
        }
    }
}
#endif
