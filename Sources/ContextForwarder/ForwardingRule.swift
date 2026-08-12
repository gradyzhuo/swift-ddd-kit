/// One declarative forwarding registration: which raw event types to inspect,
/// and how to turn one into a Published Language event. Returning nil skips
/// the record (inspected, judged not notification-worthy). The closure runs
/// in the host process — recipient/parameter resolution against the host's
/// own read models plugs in HERE.
///
/// Throwing `ForwardingError.permanent` parks the record instead of retrying —
/// use it for payloads that can never translate. Any other error is treated as
/// transient and redelivered.
public struct ForwardingRule: Sendable {
    public let eventTypes: Set<String>
    public let translate: @Sendable (ForwardedRecord) async throws -> PublishedLanguageEvent?

    public init(
        eventTypes: Set<String>,
        translate: @escaping @Sendable (ForwardedRecord) async throws -> PublishedLanguageEvent?
    ) {
        self.eventTypes = eventTypes
        self.translate = translate
    }
}
