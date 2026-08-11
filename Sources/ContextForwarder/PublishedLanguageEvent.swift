import Foundation

/// The org's Published Language envelope. Schema rules: only ADD optional
/// payload keys; breaking changes bump the versioned eventType (…".v2").
/// `recipientIds` and the payload keys required by the consumer's template
/// are the publisher's obligations — consumers never query back upstream.
public struct PublishedLanguageEvent: Codable, Equatable, Sendable {
    /// Upstream event id — the downstream idempotency key.
    public let eventId: String
    /// Versioned PL name, e.g. "OpportunityCollaboratorAdded.v1".
    public let eventType: String
    public let occurredAt: Date
    public let recipientIds: [String]
    /// Template parameters — flat string map (schema-evolution friendly).
    public let payload: [String: String]

    public init(eventId: String, eventType: String, occurredAt: Date, recipientIds: [String], payload: [String: String]) {
        self.eventId = eventId
        self.eventType = eventType
        self.occurredAt = occurredAt
        self.recipientIds = recipientIds
        self.payload = payload
    }

    public static let wireEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public static let wireDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
