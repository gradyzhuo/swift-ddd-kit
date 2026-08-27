import Foundation
import PublishedLanguage

/// A single message frame delivered by Pulsar's WebSocket consumer endpoint.
public struct ConsumerFrame: Sendable, Codable {
    public let messageId: String
    public let payload: String
    public let publishTime: String?
    public let redeliveryCount: Int
    public let properties: [String: String]
    public let key: String?

    private enum CodingKeys: String, CodingKey {
        case messageId, payload, publishTime, redeliveryCount, properties, key
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageId = try container.decode(String.self, forKey: .messageId)
        payload = try container.decode(String.self, forKey: .payload)
        publishTime = try container.decodeIfPresent(String.self, forKey: .publishTime)
        // Absent means first delivery.
        redeliveryCount = try container.decodeIfPresent(Int.self, forKey: .redeliveryCount) ?? 0
        properties = try container.decodeIfPresent([String: String].self, forKey: .properties) ?? [:]
        key = try container.decodeIfPresent(String.self, forKey: .key)
    }

    public init(json: Data) throws {
        do {
            self = try JSONDecoder().decode(ConsumerFrame.self, from: json)
        } catch {
            throw ReceiveError.malformedFrame(String(decoding: json.prefix(256), as: UTF8.self))
        }
    }

    /// Base64-decodes `payload` and decodes the Published Language event from it.
    ///
    /// Pulsar's REST produce endpoint accepts a raw JSON string payload, but its
    /// WebSocket consumer endpoint returns that payload base64-encoded. Without
    /// this decode step, every consumed message would fail silently end-to-end.
    public func decodedEvent() throws -> PublishedLanguageEvent {
        guard let bytes = Data(base64Encoded: payload) else {
            throw ReceiveError.payloadNotBase64
        }
        do {
            return try PublishedLanguageEvent.wireDecoder.decode(
                PublishedLanguageEvent.self, from: bytes
            )
        } catch {
            throw ReceiveError.payloadNotDecodable(String(describing: error))
        }
    }
}

public enum ReceiveError: Error, Equatable, Sendable {
    /// A WebSocket text frame that is not a Pulsar message frame at all.
    case malformedFrame(String)
    case payloadNotBase64
    case payloadNotDecodable(String)
    /// The admin backlog probe could not read topic stats (Task 6).
    case adminProbeFailed(String)
    /// A settle or permit was attempted with no live socket (Task 7).
    case transportUnavailable(String)
}
