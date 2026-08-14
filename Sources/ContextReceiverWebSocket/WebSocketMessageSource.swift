#if os(Linux)
import ContextReceiver
import Foundation
import HTTPTypes
import Logging
import WSClient

/// Pulsar WebSocket consumer transport backed by a single socket.
///
/// Lifetime contract: **one instance is single-use.** `run()` may be called
/// exactly once; a second call throws `ReceiveError.transportUnavailable`
/// immediately rather than attempting another connection or silently
/// reusing state. On a clean close, that one `run()` finishes `frames()`
/// normally and returns; on a transport failure it finishes `frames()` by
/// throwing that same error and rethrows it — this matches
/// `PulsarMessageSource.frames()`'s documented contract exactly.
///
/// It never reconnects internally, and it must never be retried by calling
/// `run()` again on the same instance. Pulsar's WebSocket consumer is
/// pull-mode: a reconnect opens a brand-new broker-side subscription session
/// whose permit budget starts at zero. Only the host can correctly recover
/// from that, because only the host (`ContextReceiver.run()`) knows to
/// re-grant `initialPermits` — this actor has no way to tell the runner a
/// new session started underneath it. Reusing one instance would in fact be
/// *worse* than that stall: `stream`/`continuation` are created once and
/// `frames()` always returns the same one, so a second `run()` after the
/// first has finished would reconnect a live socket underneath an already-
/// finished stream — every subsequent `yield` becomes a silent no-op, and
/// the host's `for try await` loop has already exited looking like a clean
/// shutdown while the broker drops messages into a socket nobody is
/// listening to. So supervision means **discard this instance and construct
/// a new one** — backoff and re-granting initial permits belong to that
/// supervising host, never to a retried call on this actor.
public actor WebSocketMessageSource: PulsarMessageSource {
    private let endpoint: ConsumerEndpoint
    private let authorizationHeader: @Sendable () async throws -> String?
    private let logger: Logger

    private var outbound: WebSocketOutboundWriter?
    /// Guards against a second `run()` call reusing an already-finished
    /// `stream`/`continuation` pair. See the type doc.
    private var hasStarted = false
    private nonisolated let stream: AsyncThrowingStream<ConsumerFrame, any Error>
    private nonisolated let continuation: AsyncThrowingStream<ConsumerFrame, any Error>.Continuation

    /// Bound on `grantPermits`' wait for a live socket. See `waitForSocketReady`.
    private let readinessTimeout: Duration
    private static let readinessPollInterval: Duration = .milliseconds(50)

    public init(
        endpoint: ConsumerEndpoint,
        authorizationHeader: @escaping @Sendable () async throws -> String? = { nil },
        readinessTimeout: Duration = .seconds(10),
        logger: Logger
    ) {
        self.endpoint = endpoint
        self.authorizationHeader = authorizationHeader
        self.readinessTimeout = readinessTimeout
        self.logger = logger
        (self.stream, self.continuation) = AsyncThrowingStream.makeStream()
    }

    /// Built eagerly in `init`, not lazily on first call: if the continuation
    /// were only created (or only stored on the actor) once `frames()` runs,
    /// there would be a window between the host granting initial permits and
    /// the host beginning to iterate this stream during which the broker can
    /// legitimately push frames that arrive with nowhere to land and are
    /// silently dropped — each one a permit spent with nothing to settle.
    public nonisolated func frames() -> AsyncThrowingStream<ConsumerFrame, any Error> {
        stream
    }

    private func setOutbound(_ writer: WebSocketOutboundWriter?) {
        self.outbound = writer
    }

    private func yield(_ frame: ConsumerFrame) {
        continuation.yield(frame)
    }

    /// Connects once and pumps frames until the socket closes or fails. Does
    /// not reconnect, and must not be called again after it returns or
    /// throws — see the type doc for the supervision contract.
    public func run() async throws {
        // Checked (and set) before the `defer` below is even registered: a
        // second call must throw immediately, never register another
        // `finish` against a stream that already finished on the first call.
        guard !hasStarted else {
            throw ReceiveError.transportUnavailable(
                "WebSocketMessageSource is single-use; construct a new instance to reconnect"
            )
        }
        hasStarted = true

        defer { continuation.finish() }
        do {
            try await connectOnce()
        } catch {
            // A second `finish` (the bare one in the `defer` above) is
            // harmless: the first call to finish a stream wins.
            continuation.finish(throwing: error)
            throw error
        }
    }

    private func connectOnce() async throws {
        // Actor-isolated and synchronous, so it runs strictly after this
        // connection's own `setOutbound` calls and before the next
        // connection (if any) can start. An unstructured `Task` doing this
        // clear instead — as a prior version of this file did — has no such
        // ordering guarantee and can land after a *newer* connection's
        // `setOutbound`, permanently nulling out a healthy socket's writer.
        defer { outbound = nil }

        let configuration = Self.makeConfiguration(authorization: try await authorizationHeader())

        _ = try await WebSocketClient.connect(
            url: endpoint.url,
            configuration: configuration,
            logger: logger
        ) { inbound, outbound, _ in
            await self.setOutbound(outbound)
            // Pulsar sends JSON text frames.
            for try await message in inbound.messages(maxSize: 1 << 20) {
                guard case .text(let json) = message else { continue }
                do {
                    await self.yield(try ConsumerFrame(json: Data(json.utf8)))
                } catch {
                    self.logNonMessageFrame(json)
                }
            }
        }
    }

    /// Builds the client configuration for one connection attempt. Pulled out
    /// of `connectOnce()` as a pure, non-isolated function so the auth-header
    /// mapping — a bearer token in, `.authorization` header out, never a
    /// query-string `token=` — is directly unit-testable without a live
    /// socket. `internal`, not `public`: this is test seam, not API surface.
    static func makeConfiguration(authorization: String?) -> WebSocketClientConfiguration {
        var configuration = WebSocketClientConfiguration()
        if let authorization {
            // Header, not the `token` query parameter: query strings are logged
            // by the broker.
            configuration.additionalHeaders = [.authorization: authorization]
        }
        configuration.autoPing = .enabled(timePeriod: .seconds(30))
        return configuration
    }

    /// A frame that fails to decode as a `ConsumerFrame` is either a routine
    /// command receipt (e.g. `{"result":"ok",...}` for an ack or permit) or
    /// the broker rejecting one of our own ack/nack/permit commands. Flow
    /// control depends entirely on permit commands being accepted, so a
    /// rejection must be visible at `error` — logging every non-message frame
    /// at `debug` would hide exactly the failure mode that causes a silent,
    /// permanent stall.
    private nonisolated func logNonMessageFrame(_ json: String) {
        let notice = try? JSONDecoder().decode(BrokerNotice.self, from: Data(json.utf8))
        let rejected = notice?.errorMsg != nil || (notice?.result).map { $0 != "ok" } == true
        if rejected {
            logger.error("broker rejected a websocket command", metadata: [
                "frame": "\(json.prefix(256))",
            ])
        } else {
            logger.debug("ignoring routine ack/permit receipt", metadata: [
                "frame": "\(json.prefix(256))",
            ])
        }
    }

    public func settle(messageId: String, as disposition: ReceiveDisposition) async throws {
        switch disposition {
        case .ack:
            try await send(ConsumerCommand.ack(messageId: messageId).json)
        case .nack:
            try await send(ConsumerCommand.negativeAcknowledge(messageId: messageId).json)
        case .dropToDeadLetter:
            // Pulsar's WebSocket API has no "send to DLQ now" command;
            // negative-acknowledging is the closest available primitive.
            // maxRedeliverCount plus deadLetterTopic on the endpoint are what
            // route repeatedly failing messages to the DLQ instead of
            // redelivering forever — without both configured, a message the
            // host has explicitly given up on loops indefinitely.
            if !endpoint.hasDeadLetterPolicy {
                logger.warning("dropToDeadLetter settled with no dead letter policy configured on the endpoint; broker will redeliver this message forever", metadata: [
                    "messageId": "\(messageId)",
                ])
            }
            try await send(ConsumerCommand.negativeAcknowledge(messageId: messageId).json)
        }
    }

    /// Permits are meaningless before a broker session exists. `run()` and the
    /// host granting initial permits are started as sibling tasks with no
    /// other ordering guarantee, so throwing immediately here (as `settle`
    /// does) would spuriously fail startup almost every time — the socket
    /// simply hasn't connected yet. Waiting, bounded, is the correct
    /// behaviour; a settle failure, in contrast, means a session that
    /// existed has already ended, which the caller already handles.
    public func grantPermits(_ count: Int) async throws {
        try await waitForSocketReady()
        try await send(ConsumerCommand.permit(count: count).json)
    }

    /// Polls actor-isolated state rather than registering a continuation:
    /// with no external timer/reactor to drive resumption, a poll loop
    /// cannot leak or double-resume, which a hand-rolled continuation
    /// paired with a race against a timeout task would risk getting wrong.
    /// Bounded so a socket that never arrives (bad endpoint, broker down,
    /// `run()` never started) fails loudly instead of hanging the caller.
    private func waitForSocketReady() async throws {
        guard outbound == nil else { return }
        let deadline = ContinuousClock.now.advanced(by: readinessTimeout)
        while outbound == nil {
            guard ContinuousClock.now < deadline else {
                throw ReceiveError.transportUnavailable(
                    "no socket became ready within \(readinessTimeout)"
                )
            }
            try await Task.sleep(for: Self.readinessPollInterval)
        }
    }

    private func send(_ json: String) async throws {
        guard let outbound else {
            throw ReceiveError.transportUnavailable("socket not connected")
        }
        try await outbound.writeTextMessage(json)
    }
}

/// Minimal shape of Pulsar's non-message WebSocket replies (ack/permit
/// receipts, and error notices when a command is rejected) — just enough to
/// tell the two apart for logging.
private struct BrokerNotice: Decodable {
    let result: String?
    let errorMsg: String?
}
#endif
