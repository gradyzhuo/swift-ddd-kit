import Foundation

/// The org's Published Language envelope. Schema rules: only ADD optional
/// payload keys, and envelope fields are likewise only ever added as
/// optionals (absent on the wire when nil); breaking changes bump the versioned eventType (…".v2").
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
    /// Pulsar partition key. `Key_Shared` guarantees ordering per key, so hosts
    /// that need per-aggregate ordering set this to the aggregate id. Optional
    /// for wire compatibility; falls back to `eventId`, which yields a unique
    /// key per message and therefore no ordering guarantee.
    public let partitionKey: String?
    /// The identity that triggered the upstream event (e.g. the operator's
    /// account id); nil when the event was system-triggered or the publisher
    /// doesn't know. Omitted from the wire when nil.
    public let actorId: String?

    public init(eventId: String, eventType: String, occurredAt: Date, recipientIds: [String], payload: [String: String], partitionKey: String? = nil, actorId: String? = nil) {
        self.eventId = eventId
        self.eventType = eventType
        self.occurredAt = occurredAt
        self.recipientIds = recipientIds
        self.payload = payload
        self.partitionKey = partitionKey
        self.actorId = actorId
    }

    /// The key actually sent to Pulsar.
    public var effectivePartitionKey: String { partitionKey ?? eventId }

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
