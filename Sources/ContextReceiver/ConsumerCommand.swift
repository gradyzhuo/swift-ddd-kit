import Foundation

/// Wire commands sent to Pulsar's WebSocket consumer endpoint. Kept in the
/// portable target rather than inline in the Linux-only transport: these
/// three payloads are the most consequential strings this module sends (an
/// escaping mistake here corrupts an ack or a permit grant), and living
/// behind a Linux-only file is exactly what made them the least tested code
/// in the transport. Building them with `JSONEncoder` instead of string
/// interpolation also means a broker-supplied `messageId` containing a `"`
/// or `\` cannot break the frame.
public enum ConsumerCommand: Sendable {
    /// Acknowledge successful handling of a message.
    case ack(messageId: String)
    /// Negatively acknowledge a message; the broker redelivers it, subject
    /// to `maxRedeliverCount`/`deadLetterTopic` on the endpoint.
    case negativeAcknowledge(messageId: String)
    /// Pull-mode flow control: ask the broker for `count` more messages.
    case permit(count: Int)

    private struct AckPayload: Encodable {
        let messageId: String
    }

    private struct NegativeAcknowledgePayload: Encodable {
        let type = "negativeAcknowledge"
        let messageId: String
    }

    private struct PermitPayload: Encodable {
        let type = "permit"
        let permitMessages: Int
    }

    /// The exact JSON text frame to send over the socket.
    public var json: String {
        let data: Data
        switch self {
        case .ack(let messageId):
            // Encoding a struct of two known-safe String/Int fields cannot
            // throw (no dates, no non-finite floating point values).
            data = try! JSONEncoder().encode(AckPayload(messageId: messageId))
        case .negativeAcknowledge(let messageId):
            data = try! JSONEncoder().encode(NegativeAcknowledgePayload(messageId: messageId))
        case .permit(let count):
            data = try! JSONEncoder().encode(PermitPayload(permitMessages: count))
        }
        return String(decoding: data, as: UTF8.self)
    }
}
