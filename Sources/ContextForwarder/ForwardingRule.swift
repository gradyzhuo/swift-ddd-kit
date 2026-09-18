import PublishedLanguage

/// One declarative forwarding registration: which raw event types to inspect,
/// and how to turn one into Published Language events. Returning an empty array skips
/// the record (inspected, judged not notification-worthy). The closure runs
/// in the host process — recipient/parameter resolution against the host's
/// own read models plugs in HERE.
///
/// When `translate` returns more than one event for a single record (e.g. one per
/// notification channel), each event MUST carry a stable-across-retries, mutually-distinct
/// `eventId` — e.g. `"\(record.eventId)#mail"`, `"\(record.eventId)#inApp"`. A retry re-runs
/// `translate` from scratch and re-publishes every event it returns, and downstream consumers
/// dedup on `eventId` to absorb exactly that; without a stable, distinct id per event, dedup
/// silently breaks and duplicate notifications reach production.
///
/// Throwing `ForwardingError.permanent` parks the record instead of retrying —
/// use it for payloads that can never translate. Any other error is treated as
/// transient and redelivered.
public struct ForwardingRule: Sendable {
    public let eventTypes: Set<String>
    public let translate: @Sendable (ForwardedRecord) async throws -> [PublishedLanguageEvent]

    public init(
        eventTypes: Set<String>,
        translate: @escaping @Sendable (ForwardedRecord) async throws -> [PublishedLanguageEvent]
    ) {
        self.eventTypes = eventTypes
        self.translate = translate
    }
}
