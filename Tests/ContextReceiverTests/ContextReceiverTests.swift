import Foundation
import Logging
import Testing
import PublishedLanguage
@testable import ContextReceiver

@Suite("ContextReceiver runner")
struct ContextReceiverTests {
    private struct Transient: Error, TransientReceiveError {}

    private actor RecordingHandler: PublishedLanguageHandler {
        private(set) var handled: [ReceivedRecord] = []
        private let thrown: (any Error)?
        init(throwing thrown: (any Error)? = nil) { self.thrown = thrown }
        func handle(_ record: ReceivedRecord) async throws {
            handled.append(record)
            if let thrown { throw thrown }
        }
        var handledIds: [String] { handled.map(\.event.eventId) }
    }

    private func frame(id: String, eventId: String, redeliveryCount: Int = 0) throws -> ConsumerFrame {
        let event = """
        {"eventId":"\(eventId)","eventType":"T.v1","occurredAt":"2026-08-14T01:02:03Z",\
        "recipientIds":["u-1"],"payload":{}}
        """
        let b64 = Data(event.utf8).base64EncodedString()
        return try ConsumerFrame(json: Data("""
        {"messageId":"\(id)","payload":"\(b64)","redeliveryCount":\(redeliveryCount)}
        """.utf8))
    }

    private func badFrame(id: String) throws -> ConsumerFrame {
        try ConsumerFrame(json: Data(#"{"messageId":"\#(id)","payload":"!!!not base64!!!"}"#.utf8))
    }

    private var logger: Logger { Logger(label: "test") }

    @Test func acksAfterSuccessfulHandling() async throws {
        let source = FakeMessageSource(frames: [try frame(id: "m-1", eventId: "e-1")])
        let handler = RecordingHandler()
        try await ContextReceiver(source: source, handler: handler, logger: logger).run()
        #expect(await handler.handledIds == ["e-1"])
        #expect(await source.settlements.map(\.disposition) == [.ack])
    }

    @Test func nacksWhenHandlerThrowsTransiently() async throws {
        let source = FakeMessageSource(frames: [try frame(id: "m-1", eventId: "e-1")])
        let handler = RecordingHandler(throwing: Transient())
        try await ContextReceiver(source: source, handler: handler, logger: logger).run()
        #expect(await source.settlements == [Settlement(messageId: "m-1", disposition: .nack)])
    }

    /// An undecodable payload must never reach the handler, and must not loop.
    @Test func routesUndecodableFramesToDeadLetterWithoutHandling() async throws {
        let source = FakeMessageSource(frames: [try badFrame(id: "m-bad")])
        let handler = RecordingHandler()
        try await ContextReceiver(source: source, handler: handler, logger: logger).run()
        #expect(await handler.handled.isEmpty)
        #expect(await source.settlements == [Settlement(messageId: "m-bad", disposition: .dropToDeadLetter)])
    }

    @Test func grantsInitialPermitsBeforeConsuming() async throws {
        let source = FakeMessageSource(frames: [])
        var flow = ContextReceiver.FlowSettings()
        flow.initialPermits = 42
        try await ContextReceiver(
            source: source, handler: RecordingHandler(), flow: flow, logger: logger
        ).run()
        #expect(await source.grantedPermits == 42)
    }

    @Test func refillsPermitsAfterThresholdSettlements() async throws {
        let frames = try (1...6).map { try frame(id: "m-\($0)", eventId: "e-\($0)") }
        let source = FakeMessageSource(frames: frames)
        var flow = ContextReceiver.FlowSettings()
        flow.initialPermits = 10
        flow.permitRefillThreshold = 3
        try await ContextReceiver(
            source: source, handler: RecordingHandler(), flow: flow, logger: logger
        ).run()
        // 10 initial + two refills of 3 after the 3rd and 6th settlement.
        #expect(await source.grantedPermits == 16)
    }

    @Test func surfacesRedeliveryCountToHandler() async throws {
        let source = FakeMessageSource(frames: [try frame(id: "m-1", eventId: "e-1", redeliveryCount: 4)])
        let handler = RecordingHandler()
        try await ContextReceiver(source: source, handler: handler, logger: logger).run()
        #expect(await handler.handled.first?.redeliveryCount == 4)
        #expect(await handler.handled.first?.isRedelivery == true)
    }

    /// A settle failure must not abort the loop: the broker will redeliver on
    /// ack-timeout, so it is recoverable, and aborting would strand every
    /// message still queued behind it. This also pins the decision that
    /// permits are refilled on settle *attempts*, not just successes — with
    /// `permitRefillThreshold = 1`, a refill fires after m-1's failed settle
    /// too, so `grantedPermits` only comes out to 3 if the failed attempt
    /// still counted.
    @Test func survivesSettleFailureWithoutStrandingLaterMessages() async throws {
        let frames = try (1...3).map { try frame(id: "m-\($0)", eventId: "e-\($0)") }
        let source = FakeMessageSource(frames: frames, failingSettleMessageIds: ["m-1"])
        let handler = RecordingHandler()
        var flow = ContextReceiver.FlowSettings()
        flow.initialPermits = 0
        flow.permitRefillThreshold = 1
        try await ContextReceiver(source: source, handler: handler, flow: flow, logger: logger).run()
        #expect(await handler.handledIds == ["e-1", "e-2", "e-3"])
        #expect(await source.settlements.map(\.messageId) == ["m-2", "m-3"])
        #expect(await source.grantedPermits == 3)
    }

    @Test func propagatesTransportFailure() async throws {
        struct Dropped: Error {}
        let source = FakeMessageSource(frames: [], failure: Dropped())
        await #expect(throws: Dropped.self) {
            try await ContextReceiver(
                source: source, handler: RecordingHandler(), logger: logger
            ).run()
        }
    }
}
