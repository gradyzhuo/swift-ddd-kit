import AsyncHTTPClient
import Foundation
import Logging
import NIOCore

/// Reads the message backlog of a topic. Abstracted so the monitor is testable
/// without a broker.
public protocol DeadLetterBacklogProbe: Sendable {
    func backlogCount(topic: String) async throws -> Int
}

/// Reads `msgBacklog` from Pulsar's admin stats endpoint.
public struct PulsarAdminBacklogProbe: DeadLetterBacklogProbe {
    private let adminBaseURL: String
    private let httpClient: HTTPClient
    private let authorizationHeader: @Sendable () async throws -> String?

    public init(
        adminBaseURL: String,
        httpClient: HTTPClient,
        authorizationHeader: @escaping @Sendable () async throws -> String? = { nil }
    ) {
        self.adminBaseURL = adminBaseURL
        self.httpClient = httpClient
        self.authorizationHeader = authorizationHeader
    }

    public func backlogCount(topic: String) async throws -> Int {
        var request = HTTPClientRequest(
            url: "\(adminBaseURL)/admin/v2/persistent/\(topic)/stats"
        )
        request.method = .GET
        if let authorization = try await authorizationHeader() {
            request.headers.add(name: "Authorization", value: authorization)
        }
        let response = try await httpClient.execute(request, timeout: .seconds(10))
        let body = try await response.body.collect(upTo: 1 << 20)
        guard response.status == .ok else {
            throw ReceiveError.adminProbeFailed("HTTP \(response.status.code): \(String(buffer: body))")
        }
        struct Stats: Decodable { let msgBacklog: Int? }
        // ByteBuffer(bytes:)/readableBytesView are NIOCore spellings; the
        // Foundation-bridging ones live in NIOFoundationCompat and are not
        // portable to Linux.
        let stats = try JSONDecoder().decode(Stats.self, from: Data(body.readableBytesView))
        return stats.msgBacklog ?? 0
    }
}

/// Periodically checks a dead letter topic's backlog and alerts when it grows.
/// A message in the DLQ is a notification nobody received; by default nothing
/// surfaces that, so the framework does it rather than each host.
public struct DeadLetterMonitor: Sendable {
    private let probe: any DeadLetterBacklogProbe
    private let topic: String
    private let interval: Duration
    private let threshold: Int
    /// Bounded run length. `nil` runs until cancelled; tests pass a finite count.
    private let maxChecks: Int?
    private let logger: Logger
    private let onAlert: @Sendable (Int) async -> Void

    public init(
        probe: any DeadLetterBacklogProbe,
        topic: String,
        interval: Duration = .seconds(60),
        threshold: Int = 1,
        maxChecks: Int? = nil,
        logger: Logger,
        onAlert: @escaping @Sendable (Int) async -> Void
    ) {
        self.probe = probe
        self.topic = topic
        self.interval = interval
        self.threshold = threshold
        self.maxChecks = maxChecks
        self.logger = logger
        self.onAlert = onAlert
    }

    public func run() async throws {
        var checks = 0
        while maxChecks.map({ checks < $0 }) ?? true {
            checks += 1
            do {
                let count = try await probe.backlogCount(topic: topic)
                if count >= threshold {
                    logger.error("dead letter backlog above threshold", metadata: [
                        "topic": "\(topic)", "backlog": "\(count)", "threshold": "\(threshold)",
                    ])
                    await onAlert(count)
                }
            } catch {
                // Keep polling: the backlog is still growing whether or not we
                // can read it, and giving up would make the silence permanent.
                logger.warning("dead letter probe failed", metadata: [
                    "topic": "\(topic)", "error": "\(error)",
                ])
            }
            try await Task.sleep(for: interval)
        }
    }
}
