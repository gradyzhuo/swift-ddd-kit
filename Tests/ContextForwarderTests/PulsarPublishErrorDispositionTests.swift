import Testing
@testable import ContextForwarder

/// `PulsarRESTPublisher.PublishError` is a transport-level error, not a
/// `ForwardingError` — without its own classification it would fall through
/// `ForwardingDisposition(for:)`'s unrecognized-error default and always
/// retry, even for a broker response that can never succeed as sent.
@Suite("Pulsar publish error classification")
struct PulsarPublishErrorDispositionTests {
    @Test("a 400 (malformed payload) parks — retrying sends the exact same bytes")
    func badRequestParks() {
        let error = PulsarRESTPublisher.PublishError.unexpectedStatus(400, body: "bad request")
        #expect(ForwardingDisposition(for: error) == .park)
    }

    @Test("a 404 (unknown topic) parks")
    func notFoundParks() {
        let error = PulsarRESTPublisher.PublishError.unexpectedStatus(404, body: "not found")
        #expect(ForwardingDisposition(for: error) == .park)
    }

    @Test("a 413 (message too large) parks")
    func payloadTooLargeParks() {
        let error = PulsarRESTPublisher.PublishError.unexpectedStatus(413, body: "too large")
        #expect(ForwardingDisposition(for: error) == .park)
    }

    @Test("a 429 (rate limited) retries — the request itself was fine")
    func tooManyRequestsRetries() {
        let error = PulsarRESTPublisher.PublishError.unexpectedStatus(429, body: "slow down")
        #expect(ForwardingDisposition(for: error) == .retry)
    }

    @Test("a 408 (request timeout) retries")
    func requestTimeoutRetries() {
        let error = PulsarRESTPublisher.PublishError.unexpectedStatus(408, body: "timeout")
        #expect(ForwardingDisposition(for: error) == .retry)
    }

    @Test("a 503 (broker unavailable) retries")
    func serviceUnavailableRetries() {
        let error = PulsarRESTPublisher.PublishError.unexpectedStatus(503, body: "unavailable")
        #expect(ForwardingDisposition(for: error) == .retry)
    }

    @Test("encoding failures park — retrying encodes the same bytes and fails the same way")
    func encodingFailureParks() {
        #expect(ForwardingDisposition(for: PulsarRESTPublisher.PublishError.encodingFailed) == .park)
    }
}
