import Logging
import PublishedLanguage

/// Drives a `PulsarMessageSource` into a `PublishedLanguageHandler`, settling
/// each message with the broker. Mirrors `ContextForwarder` on the consume side.
public struct ContextReceiver: Sendable {
    public struct FlowSettings: Sendable {
        /// Permits granted before consuming starts. Bounds in-flight messages.
        public var initialPermits: Int = 100
        /// Settlements to accumulate before asking for more. Batching avoids a
        /// broker round-trip per message.
        public var permitRefillThreshold: Int = 50
        public init() {}
    }

    private let source: any PulsarMessageSource
    private let handler: any PublishedLanguageHandler
    private let flow: FlowSettings
    private let logger: Logger

    public init(
        source: any PulsarMessageSource,
        handler: any PublishedLanguageHandler,
        flow: FlowSettings = .init(),
        logger: Logger
    ) {
        self.source = source
        self.handler = handler
        self.flow = flow
        self.logger = logger
    }

    public func run() async throws {
        try await source.grantPermits(flow.initialPermits)
        var settledSinceRefill = 0

        for try await frame in source.frames() {
            let outcome = await disposition(for: frame)
            do {
                try await source.settle(messageId: frame.messageId, as: outcome)
            } catch {
                // The broker will redeliver on ack-timeout, so a failed settle
                // is recoverable. Aborting the loop would strand the rest.
                logger.error("failed to settle message", metadata: [
                    "messageId": "\(frame.messageId)",
                    "disposition": "\(outcome)",
                    "error": "\(error)",
                ])
            }

            settledSinceRefill += 1
            if settledSinceRefill >= flow.permitRefillThreshold {
                try await source.grantPermits(settledSinceRefill)
                settledSinceRefill = 0
            }
        }
    }

    /// Decides the disposition for one frame. Never throws: every outcome is a
    /// disposition, so one bad message cannot end the subscription.
    private func disposition(for frame: ConsumerFrame) async -> ReceiveDisposition {
        let event: PublishedLanguageEvent
        do {
            event = try frame.decodedEvent()
        } catch {
            logger.error("undecodable payload, routing to dead letter", metadata: [
                "messageId": "\(frame.messageId)", "error": "\(error)",
            ])
            return ReceiveDisposition(for: error)
        }

        let record = ReceivedRecord(frame: frame, event: event)
        do {
            try await handler.handle(record)
            return .ack
        } catch {
            let disposition = ReceiveDisposition(for: error)
            logger.warning("handler failed", metadata: [
                "messageId": "\(frame.messageId)",
                "eventId": "\(event.eventId)",
                "redeliveryCount": "\(record.redeliveryCount)",
                "disposition": "\(disposition)",
                "error": "\(error)",
            ])
            return disposition
        }
    }
}
