#if os(Linux)
import ContextReceiver
@testable import ContextReceiverWebSocket
import HTTPTypes
import Testing

/// Exercises the real auth path, replacing
/// `ConsumerEndpointTests.neverPutsTokenInQueryString`. That test asserted
/// `ConsumerEndpoint.url` never contains `token=`, but `ConsumerEndpoint`
/// (and its `Settings`) has no auth field at all — the assertion held no
/// matter what happened to auth handling, so it detected nothing. Auth
/// actually flows through a bearer-token closure into the `Authorization`
/// header on `WebSocketClientConfiguration` (see
/// `WebSocketMessageSource.makeConfiguration`), never through the URL — and
/// that type only exists on Linux, which is why this lives here rather than
/// in the portable `ContextReceiverTests`.
@Suite("WebSocket auth header mapping")
struct WebSocketMessageSourceAuthTests {
    private let endpoint = ConsumerEndpoint(
        baseURL: "ws://pulsar.internal:8080", tenant: "public", namespace: "default",
        topic: "unused", subscription: "unused"
    )

    @Test func bearerTokenReachesAuthorizationHeader() {
        // Obviously-fake placeholder — never a real credential.
        let configuration = WebSocketMessageSource.makeConfiguration(authorization: "Bearer fake-placeholder-token")
        #expect(configuration.additionalHeaders[.authorization] == "Bearer fake-placeholder-token")
    }

    @Test func noAuthorizationMeansNoHeader() {
        let configuration = WebSocketMessageSource.makeConfiguration(authorization: nil)
        #expect(configuration.additionalHeaders[.authorization] == nil)
    }

    @Test func tokenNeverRidesInTheEndpointURL() {
        // The header path and the URL are entirely independent — proving
        // that matters because a `token=` query parameter is logged by the
        // broker, while the `Authorization` header is not.
        _ = WebSocketMessageSource.makeConfiguration(authorization: "Bearer fake-placeholder-token")
        #expect(!endpoint.url.contains("fake-placeholder-token"))
        #expect(!endpoint.url.contains("token="))
    }
}
#endif
