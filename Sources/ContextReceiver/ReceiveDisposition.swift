/// One settled message. A named type rather than a tuple: Swift tuples do not
/// conform to `Equatable`, so `[(String, ReceiveDisposition)] == [...]` will not
/// compile and test assertions could not be written against it.
public struct Settlement: Equatable, Sendable {
    public let messageId: String
    public let disposition: ReceiveDisposition

    public init(messageId: String, disposition: ReceiveDisposition) {
        self.messageId = messageId
        self.disposition = disposition
    }
}

/// What to tell the broker about a message after the host has handled it.
public enum ReceiveDisposition: Equatable, Sendable {
    /// Handled successfully; remove from the subscription.
    case ack
    /// Retryable failure; redeliver after `negativeAckRedeliveryDelay`.
    case nack
    /// Unprocessable and always will be; push toward the dead letter topic
    /// rather than looping. Never a silent drop.
    case dropToDeadLetter
}

/// Host errors adopt this to declare themselves retryable.
public protocol TransientReceiveError: Error {}

extension ReceiveDisposition {
    public init(for error: any Error) {
        switch error {
        case is TransientReceiveError:
            self = .nack
        case ReceiveError.payloadNotBase64, ReceiveError.payloadNotDecodable:
            self = .dropToDeadLetter
        default:
            // Default to retry. Misreading a transient outage as permanent
            // loses a notification; a redelivery only costs a duplicate,
            // which host-side deterministic ids already absorb.
            self = .nack
        }
    }
}
