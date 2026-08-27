import Foundation
import Logging

/// Runs several forwarders side by side — one per source stream, each with its
/// own subscription group and checkpoint, so a stuck or failing stream cannot
/// stall the others.
///
/// Owns the restart loop hosts would otherwise hand-roll: a forwarder's `run()`
/// returns normally when the server closes the subscription stream cleanly
/// (idle timeout, broker restart, load-balancer reset), which is indistinguishable
/// from "done" at the call site — so BOTH exits back off and re-subscribe.
public struct ForwarderGroup: Sendable {
    private let forwarders: [ContextForwarder]
    private let restartDelay: Duration
    private let logger: Logger

    public init(
        forwarders: [ContextForwarder],
        restartDelay: Duration = .seconds(5),
        logger: Logger = Logger(label: "ForwarderGroup")
    ) {
        self.forwarders = forwarders
        self.restartDelay = restartDelay
        self.logger = logger
    }

    /// Idempotent setup for every member. Throws on the first genuine failure
    /// so a host's startup gate can refuse to serve with a broken forwarder.
    public func ensureAll() async throws {
        for forwarder in forwarders {
            try await forwarder.ensureSubscription()
        }
    }

    /// Runs until cancelled. Never returns normally while any member remains.
    public func run() async throws {
        await withTaskGroup(of: Void.self) { group in
            for forwarder in forwarders {
                let label = "\(forwarder.streamName)/\(forwarder.subscriptionGroupName)"
                group.addTask { [restartDelay, logger] in
                    await Self.runWithRestart(label: label, restartDelay: restartDelay, logger: logger) {
                        try await forwarder.run()
                    }
                }
            }
        }
    }

    /// The restart loop, extracted so its semantics are testable without a
    /// live forwarder. `body` returning normally is NOT "done" — the server
    /// closes subscription streams cleanly on idle timeout / broker restart /
    /// LB reset — so both exits back off before retrying.
    static func runWithRestart(
        label: String,
        restartDelay: Duration,
        logger: Logger,
        body: @Sendable () async throws -> Void
    ) async {
        while !Task.isCancelled {
            do {
                try await body()
                if Task.isCancelled { return }
                logger.warning("\(label): stream ended cleanly — restarting in \(restartDelay)")
            } catch {
                if Task.isCancelled { return }
                logger.error("\(label): stopped: \(error) — restarting in \(restartDelay)")
            }
            try? await Task.sleep(for: restartDelay)
        }
    }
}
