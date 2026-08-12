import Foundation

/// Errors a rule (or the framework) raises to steer redelivery.
public enum ForwardingError: Error, Equatable {
    /// This record will NEVER forward successfully — a malformed payload, a
    /// missing required field, an event shape the rule cannot handle. Retrying
    /// only delays the inevitable, so the forwarder parks it immediately
    /// instead of burning the retry budget.
    case permanent(reason: String)
}

/// What the forwarder does with a failed record.
public enum ForwardingDisposition: Equatable, Sendable {
    /// Transient: redeliver and try again (the safe default for unknown errors).
    case retry
    /// Permanent: park now. Parked messages stop being delivered — the parked
    /// monitor is what makes them visible.
    case park

    /// Transient unless the error explicitly says otherwise.
    public init(for error: any Error) {
        if error is ForwardingError {
            self = .park
        } else {
            self = .retry
        }
    }
}
