import PublishedLanguage

/// A decoded Published Language event plus the broker delivery metadata the
/// host needs to reason about retries.
public struct ReceivedRecord: Sendable {
    public let event: PublishedLanguageEvent
    public let messageId: String
    public let redeliveryCount: Int
    public let key: String?
    public let properties: [String: String]

    /// True when the broker has delivered this message before. Hosts rely on
    /// deterministic aggregate ids for idempotency; this only informs logging
    /// and escalation decisions.
    public var isRedelivery: Bool { redeliveryCount > 0 }

    public init(frame: ConsumerFrame, event: PublishedLanguageEvent) {
        self.event = event
        self.messageId = frame.messageId
        self.redeliveryCount = frame.redeliveryCount
        self.key = frame.key
        self.properties = frame.properties
    }
}
