import Foundation
import KurrentDB
import Logging

/// Embeddable forwarder: persistent-subscribes the host context's OWN
/// KurrentDB (server-side checkpoint — no dual-write), translates matching
/// events to Published Language, publishes to Pulsar, THEN acks.
/// At-least-once: downstream dedups on eventId.
public struct ContextForwarder: Sendable {
    /// Subscription creation settings. Defaults chosen for forwarding work
    /// (host lookups + an HTTP publish per event): 30s message timeout —
    /// NOTE: swift-kurrentdb's own CreateSettings default is .ms(30), thirty
    /// MILLISECONDS (upstream units bug vs the server's 30s default) — never
    /// rely on it.
    public struct SubscriptionSettings: Sendable {
        public var messageTimeout: Duration = .seconds(30)
        public var startFrom: StartPosition = .end
        public enum StartPosition: Sendable { case start, end }
        public init() {}
    }

    private let client: KurrentDBClient
    private let publisher: any PublishedLanguagePublisher
    private let stream: String
    private let groupName: String
    private let rules: [ForwardingRule]
    private let logger: Logger
    private let subscriptionSettings: SubscriptionSettings

    public init(
        client: KurrentDBClient,
        publisher: any PublishedLanguagePublisher,
        stream: String,
        groupName: String,
        rules: [ForwardingRule] = [],
        subscriptionSettings: SubscriptionSettings = .init(),
        logger: Logger = Logger(label: "ContextForwarder")
    ) {
        self.client = client
        self.publisher = publisher
        self.stream = stream
        self.groupName = groupName
        self.rules = rules
        self.subscriptionSettings = subscriptionSettings
        self.logger = logger
    }

    /// Builder-style registration (immutable copies).
    public func register(_ rule: ForwardingRule) -> ContextForwarder {
        ContextForwarder(
            client: client, publisher: publisher, stream: stream,
            groupName: groupName, rules: rules + [rule],
            subscriptionSettings: subscriptionSettings, logger: logger)
    }

    /// Idempotent: creates the persistent subscription group (resolveLink on,
    /// for $ce- source streams); tolerates already-exists.
    ///
    /// The start position (`subscriptionSettings.startFrom`) applies ONLY at
    /// group creation — an existing group keeps its server-side checkpoint
    /// regardless of what's passed here. Default `.end` means no backfill of
    /// history on first enablement of a group.
    public func ensureSubscription() async throws {
        do {
            try await client.persistentSubscriptions(stream: stream, group: groupName).create {
                $0.settings.resolveLink = true
                // swift-kurrentdb's `TimeSpan` (Core/TimeSpan.swift:11-16) only
                // offers `.ticks`/`.ms` — convert our `Duration` to whole
                // milliseconds for `CreateSettings.messageTimeout`
                // (Core/PersistenSubscription/PersistentSubscription.Settings.swift:18,47).
                $0.settings.messageTimeout = .ms(subscriptionSettings.messageTimeout.milliseconds)
                // `Options.revision: RevisionCursor` (Core/Cursor/RevisionCursor.swift:9-16),
                // consumed by `SpecifiedStream.Create.Options.build()`
                // (PersistentSubscriptions/Usecase/Specified/PersistentSubscriptions.SpecifiedStream.Create.swift:71,87-95).
                switch subscriptionSettings.startFrom {
                case .start: $0.revision = .start
                case .end: $0.revision = .end
                }
            }
        } catch {
            // `create` is `throws(KurrentError)` (PersistentSubscriptions+Specified.swift:18),
            // so `error` here is already typed as `KurrentError`.
            // Only already-exists is the expected steady state (re-running
            // ensureSubscription against a group created by a prior process
            // start). `KurrentError.resourceAlreadyExists`
            // (Core/Error/KurrentError.swift:35) is the only case swallowed;
            // everything else (connection-refused -> .grpcConnectionError,
            // auth failures -> .accessDenied, etc.) must reach the caller so
            // hosts' setup gates actually trip.
            guard case .resourceAlreadyExists = error else { throw error }
            logger.debug("ensureSubscription: group already exists (tolerated)")
        }
    }

    /// Consumes until cancelled. Publish THEN ack; failures nack for redelivery.
    /// Records matching no rule are acked immediately (skip).
    public func run() async throws {
        let subscription = try await client.persistentSubscriptions(stream: stream, group: groupName).subscribe()
        for try await result in subscription.events {
            if Task.isCancelled { return }
            let event = result.event
            do {
                let record = ForwardedRecord(from: event)
                for rule in rules where rule.eventTypes.contains(record.eventType) {
                    if let published = try await rule.translate(record) {
                        try await publisher.publish(published)
                        logger.info("forwarded \(record.eventType) -> \(published.eventType) (\(published.eventId))")
                    }
                }
                try await subscription.ack(readEvents: event)
            } catch {
                switch ForwardingDisposition(for: error) {
                case .park:
                    logger.error("forwarding permanently failed, parking: \(error)")
                    try await subscription.nack(readEvents: event, action: .park, reason: "\(error)")
                case .retry:
                    logger.error("forwarding failed, will retry: \(error)")
                    try await subscription.nack(readEvents: event, action: .retry, reason: "\(error)")
                }
            }
        }
    }
}

extension Duration {
    /// Converts to whole milliseconds for swift-kurrentdb's `TimeSpan.ms`
    /// (Core/TimeSpan.swift:15, `Int32`). Truncates any sub-millisecond
    /// remainder — irrelevant at the second-level granularity we configure.
    fileprivate var milliseconds: Int32 {
        let components = self.components
        let whole = components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
        return Int32(whole)
    }
}

extension ForwardedRecord {
    /// Maps a persistent-subscription delivery to the kit-agnostic record.
    ///
    /// - `event` here is a `ReadEvent` (swift-kurrentdb
    ///   `Sources/KurrentDB/Core/Event/ReadEvent.swift`), exposing `record`
    ///   (the resolved `RecordedEvent`) and an optional `link` (the raw link
    ///   event on a `$ce-` projection stream). We read from `.record`, which
    ///   is the resolved original event when `resolveLink = true` is set at
    ///   subscription-create time (confirmed in
    ///   `PersistentSubscriptions.SpecifiedStream.Create.swift` /
    ///   `PersistentSubscription.CreateSettings`).
    init(from event: ReadEvent) {
        let record = event.record
        self.init(
            eventType: record.eventType,
            streamName: record.streamIdentifier.name,
            eventId: record.id.uuidString,
            data: record.data)
    }
}
