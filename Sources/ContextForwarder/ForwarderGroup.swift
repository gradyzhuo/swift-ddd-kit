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
                group.addTask { [restartDelay, logger] in
                    while !Task.isCancelled {
                        do {
                            try await forwarder.run()
                            logger.warning("forwarder \(forwarder.streamName)/\(forwarder.subscriptionGroupName) stream ended cleanly — restarting in \(restartDelay)")
                        } catch {
                            logger.error("forwarder \(forwarder.streamName)/\(forwarder.subscriptionGroupName) stopped: \(error) — restarting in \(restartDelay)")
                        }
                        if Task.isCancelled { return }
                        try? await Task.sleep(for: restartDelay)
                    }
                }
            }
        }
    }
}
