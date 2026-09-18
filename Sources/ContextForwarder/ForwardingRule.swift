import PublishedLanguage

/// One declarative forwarding registration: which raw event types to inspect,
/// and how to turn one into Published Language events. Returning an empty array skips
/// the record (inspected, judged not worth forwarding). The closure runs
/// in the host process — lookups against the host's own read models plug in HERE.
///
/// When `translate` returns more than one event for a single record (e.g. one per
/// downstream destination), each event MUST carry a stable-across-retries, mutually-distinct
/// `eventId` — e.g. `"\(record.eventId)#a"`, `"\(record.eventId)#b"`. A retry re-runs
/// `translate` from scratch and re-publishes every event it returns, and downstream consumers
/// dedup on `eventId` to absorb exactly that; without a stable, distinct id per event, dedup
/// silently breaks and duplicate events reach consumers.
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
