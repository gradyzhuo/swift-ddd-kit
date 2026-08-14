#if os(Linux)
import ContextReceiver
import Foundation
import HTTPTypes
import Logging
import NIOCore
import WSClient

/// Pulsar WebSocket consumer transport. Owns the socket, translates frames,
/// and reconnects with backoff. Unacked messages are redelivered by the broker
/// after a reconnect, which is why at-least-once plus host-side deterministic
/// ids is the required contract.
public actor WebSocketMessageSource: PulsarMessageSource {
    private let endpoint: ConsumerEndpoint
    private let authorizationHeader: @Sendable () async throws -> String?
    private let reconnectBackoff: [Duration]
    private let logger: Logger

    private var outbound: WebSocketOutboundWriter?
    private var continuation: AsyncThrowingStream<ConsumerFrame, any Error>.Continuation?

    public init(
        endpoint: ConsumerEndpoint,
        authorizationHeader: @escaping @Sendable () async throws -> String? = { nil },
        reconnectBackoff: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(15)],
        logger: Logger
    ) {
        self.endpoint = endpoint
        self.authorizationHeader = authorizationHeader
        self.reconnectBackoff = reconnectBackoff
        self.logger = logger
    }

    public nonisolated func frames() -> AsyncThrowingStream<ConsumerFrame, any Error> {
        AsyncThrowingStream { continuation in
            Task { await self.store(continuation) }
        }
    }

    private func store(_ continuation: AsyncThrowingStream<ConsumerFrame, any Error>.Continuation) {
        self.continuation = continuation
    }

    private func setOutbound(_ writer: WebSocketOutboundWriter?) {
        self.outbound = writer
    }

    private func yield(_ frame: ConsumerFrame) {
        continuation?.yield(frame)
    }

    /// Connects and pumps frames until cancelled, reconnecting on drop.
    public func run() async throws {
        var attempt = 0
        while !Task.isCancelled {
            do {
                try await connectOnce()
                attempt = 0  // clean close: reset backoff
            } catch {
                if Task.isCancelled { break }
                let delay = reconnectBackoff[min(attempt, reconnectBackoff.count - 1)]
                attempt += 1
                logger.warning("consumer socket dropped, reconnecting", metadata: [
                    "error": "\(error)", "delay": "\(delay)",
                ])
                try await Task.sleep(for: delay)
            }
        }
        continuation?.finish()
    }

    private func connectOnce() async throws {
        var configuration = WebSocketClientConfiguration()
        if let authorization = try await authorizationHeader() {
            // Header, not the `token` query parameter: query strings are logged
            // by the broker.
            configuration.additionalHeaders = [.authorization: authorization]
        }
        configuration.autoPing = .enabled(timePeriod: .seconds(30))

        _ = try await WebSocketClient.connect(
            url: endpoint.url,
            configuration: configuration,
            logger: logger
        ) { inbound, outbound, _ in
            await self.setOutbound(outbound)
            defer { Task { await self.setOutbound(nil) } }
            // Pulsar sends JSON text frames.
            for try await message in inbound.messages(maxSize: 1 << 20) {
                guard case .text(let json) = message else { continue }
                do {
                    await self.yield(try ConsumerFrame(json: Data(json.utf8)))
                } catch {
                    // Not a message frame (ack receipt, error notice, ping).
                    self.logger.debug("ignoring non-message frame", metadata: [
                        "frame": "\(json.prefix(256))",
                    ])
                }
            }
        }
    }

    public func settle(messageId: String, as disposition: ReceiveDisposition) async throws {
        let json: String
        switch disposition {
        case .ack:
            json = #"{"messageId":"\#(messageId)"}"#
        case .nack, .dropToDeadLetter:
            // Both negatively acknowledge; maxRedeliverCount routes repeatedly
            // failing messages to the dead letter topic.
            json = #"{"type":"negativeAcknowledge","messageId":"\#(messageId)"}"#
        }
        try await send(json)
    }

    public func grantPermits(_ count: Int) async throws {
        try await send(#"{"type":"permit","permitMessages":\#(count)}"#)
    }

    private func send(_ json: String) async throws {
        guard let outbound else {
            throw ReceiveError.transportUnavailable("socket not connected")
        }
        try await outbound.writeTextMessage(json)
    }
}
#endif
