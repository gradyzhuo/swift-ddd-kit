import Foundation

/// Errors a rule (or the framework) raises to steer redelivery.
public enum ForwardingError: Error, Equatable, Sendable {
    /// This record will NEVER forward successfully — a malformed payload, a
    /// missing required field, an event shape the rule cannot handle. Retrying
    /// only delays the inevitable, so the forwarder parks it immediately
    /// instead of burning the retry budget.
    case permanent(reason: String)
}

extension ForwardingError {
    /// Exhaustive by construction: adding a case forces a decision here.
    var disposition: ForwardingDisposition {
        switch self {
        case .permanent: return .park
        }
    }
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
        if let forwarding = error as? ForwardingError {
            self = forwarding.disposition
        } else if let publish = error as? PulsarRESTPublisher.PublishError {
            self = publish.disposition
        } else {
            // Transient is the safe default: an unrecognized failure gets
            // redelivered rather than silently parked.
            self = .retry
        }
    }

    /// Worst-case-with-a-second-chance precedence across several rule failures:
    /// a transient failure wins over a permanent one, because redelivery is the
    /// only way the transient rule ever succeeds — the permanent one merely
    /// fails again, bounded by the subscription's maxRetryCount.
    /// No failures at all yields nil (the record is acked).
    public init?(forAnyOf errors: [any Error]) {
        guard !errors.isEmpty else { return nil }
        self = errors.contains { ForwardingDisposition(for: $0) == .retry } ? .retry : .park
    }
}
