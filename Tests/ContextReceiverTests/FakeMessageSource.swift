import Foundation
import Testing
@testable import ContextReceiver

actor FakeMessageSource: PulsarMessageSource {
    // `nonisolated let` so `frames()` can read them without hopping onto the
    // actor — an `await` on an immutable Sendable property is a warning.
    private nonisolated let queued: [ConsumerFrame]
    /// When set, `frames()` throws this after yielding everything queued.
    /// `& Sendable` is required: a bare `any Error` is not Sendable and cannot
    /// be held in a `nonisolated let`.
    private nonisolated let failure: (any Error & Sendable)?
    private(set) var settlements: [Settlement] = []
    private(set) var grantedPermits = 0

    init(frames: [ConsumerFrame], failure: (any Error & Sendable)? = nil) {
        self.queued = frames
        self.failure = failure
    }

    nonisolated func frames() -> AsyncThrowingStream<ConsumerFrame, any Error> {
        AsyncThrowingStream { continuation in
            for frame in queued { continuation.yield(frame) }
            if let failure {
                continuation.finish(throwing: failure)
            } else {
                continuation.finish()
            }
        }
    }

    func settle(messageId: String, as disposition: ReceiveDisposition) async throws {
        settlements.append(Settlement(messageId: messageId, disposition: disposition))
    }

    func grantPermits(_ count: Int) async throws {
        grantedPermits += count
    }
}

@Suite("Receive disposition")
struct ReceiveDispositionTests {
    private struct Transient: Error, TransientReceiveError {}
    private struct Permanent: Error {}

    @Test func transientErrorsNack() {
        #expect(ReceiveDisposition(for: Transient()) == .nack)
    }

    /// A payload that cannot be decoded will never decode; retrying is pointless.
    @Test func decodeFailuresGoToDeadLetter() {
        #expect(ReceiveDisposition(for: ReceiveError.payloadNotBase64) == .dropToDeadLetter)
        #expect(ReceiveDisposition(for: ReceiveError.payloadNotDecodable("x")) == .dropToDeadLetter)
    }

    /// Unknown errors are treated as retryable: a transient outage misclassified
    /// as permanent loses a notification, which is worse than a redelivery.
    @Test func unknownErrorsDefaultToNack() {
        #expect(ReceiveDisposition(for: Permanent()) == .nack)
    }
}

@Suite("Fake message source")
struct FakeMessageSourceTests {
    @Test func yieldsFramesThenFinishes() async throws {
        let frame = try ConsumerFrame(json: Data(#"{"messageId":"m-1","payload":"e30="}"#.utf8))
        let source = FakeMessageSource(frames: [frame])
        var seen: [String] = []
        for try await f in source.frames() { seen.append(f.messageId) }
        #expect(seen == ["m-1"])
    }

    @Test func recordsSettlementsAndPermits() async throws {
        let source = FakeMessageSource(frames: [])
        try await source.settle(messageId: "m-1", as: .ack)
        try await source.grantPermits(5)
        #expect(await source.settlements == [Settlement(messageId: "m-1", disposition: .ack)])
        #expect(await source.grantedPermits == 5)
    }
}
