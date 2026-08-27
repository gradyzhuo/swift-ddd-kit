import Foundation
import KurrentDB
import Logging

/// Embeddable forwarder: persistent-subscribes the host context's OWN
/// KurrentDB (server-side checkpoint — no dual-write), translates matching
/// events to Published Language, publishes to Pulsar, THEN acks.
/// At-least-once: downstream dedups on eventId.
///
/// **Ack granularity is per delivery, not per rule** (accepted trade-off): all
/// rules matching a record are attempted, then ONE disposition covers the whole
/// record. A retry therefore re-publishes rules that already succeeded —
/// consumers dedup on `eventId`, which absorbs it. A record is parked only when
/// every failure is permanent, so a healthy rule is never stranded by a broken
/// sibling.
///
/// **The loop is strictly sequential** (accepted trade-off): one record at a
/// time, so throughput is bounded by translate + publish latency. Ordering
/// within the source stream is preserved, which is the property worth keeping;
/// revisit only if a high-frequency stream ever needs forwarding.
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
        /// Deliveries attempted before the server parks the message. Mirrors
        /// KurrentDB's own default; lower it when a rule's failures are cheap
        /// to diagnose and expensive to retry.
        public var maxRetryCount: Int32 = 10
        public init() {}
    }

    /// Parked messages stop being delivered silently — nothing throws, nothing
    /// logs, the downstream simply never receives those events. This poll is
    /// the only thing that makes that visible.
    public struct MonitoringSettings: Sendable {
        /// nil disables the poll entirely.
        public var parkedCheckInterval: Duration? = .seconds(60)
        /// Called with the parked count whenever it is greater than zero.
        /// Defaults to an error-level log line.
        public var onParkedDetected: (@Sendable (Int64) async -> Void)?
        public init() {}
    }

    private let client: KurrentDBClient
    private let publisher: any PublishedLanguagePublisher
    private let stream: String
    private let groupName: String
    private let rules: [ForwardingRule]

    /// The source stream this forwarder subscribes to. Read-only; exposed so
    /// callers running several forwarders side by side (see `ForwarderGroup`)
    /// can identify which one logged what.
    public var streamName: String { stream }

    /// The persistent-subscription group name this forwarder consumes from.
    /// Read-only, for the same reason as `streamName`.
    public var subscriptionGroupName: String { groupName }
    private let logger: Logger
    private let subscriptionSettings: SubscriptionSettings
    private let monitoring: MonitoringSettings

    public init(
        client: KurrentDBClient,
        publisher: any PublishedLanguagePublisher,
        stream: String,
        groupName: String,
        rules: [ForwardingRule] = [],
        subscriptionSettings: SubscriptionSettings = .init(),
        monitoring: MonitoringSettings = .init(),
        logger: Logger = Logger(label: "ContextForwarder")
    ) {
        self.client = client
        self.publisher = publisher
        self.stream = stream
        self.groupName = groupName
        self.rules = rules
        self.subscriptionSettings = subscriptionSettings
        self.monitoring = monitoring
        self.logger = logger
    }

    /// Builder-style registration (immutable copies).
    public func register(_ rule: ForwardingRule) -> ContextForwarder {
        ContextForwarder(
            client: client, publisher: publisher, stream: stream,
            groupName: groupName, rules: rules + [rule],
            subscriptionSettings: subscriptionSettings, monitoring: monitoring,
            logger: logger)
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
                // `CreateSettings.maxRetryCount: Int32`
                // (Core/PersistenSubscription/PersistentSubscription.Settings.swift:20-21),
                // default 10 — mirrored by `SubscriptionSettings.maxRetryCount`.
                $0.settings.maxRetryCount = subscriptionSettings.maxRetryCount
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

    /// Consumes until cancelled, while polling for parked messages in
    /// parallel. The first child to finish — whether by throwing or by
    /// returning normally — tears the other down; neither is expected to
    /// return on its own outside of cancellation.
    public func run() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.consume() }
            if let interval = monitoring.parkedCheckInterval {
                group.addTask { try await self.pollParked(every: interval) }
            }
            // Surface the first failure and tear the sibling down with it.
            try await group.next()
            group.cancelAll()
        }
    }

    /// Consumes until cancelled. Every rule matching a record is attempted —
    /// even after one fails — because a parked record is never redelivered,
    /// so a later rule's turn right now is its only chance to translate this
    /// record; letting one broken rule strand a healthy sibling would be a
    /// silent-loss path. Failures are collected and reduced to ONE disposition
    /// for the whole record via `ForwardingDisposition(forAnyOf:)`: any
    /// transient failure retries (redelivery is the transient rule's only path
    /// to success; a permanent one just fails again, bounded by
    /// `maxRetryCount`), else any permanent failure parks, else the record is
    /// acked. A retry re-publishes rules that already succeeded on this
    /// delivery — consumers dedup on `eventId`, which absorbs it. Records
    /// matching no rule are acked immediately (skip).
    private func consume() async throws {
        let subscription = try await client.persistentSubscriptions(stream: stream, group: groupName).subscribe()
        for try await result in subscription.events {
            if Task.isCancelled { return }
            let event = result.event
            let record = ForwardedRecord(from: event)
            var failures: [any Error] = []
            for rule in rules where rule.eventTypes.contains(record.eventType) {
                do {
                    if let published = try await rule.translate(record) {
                        try await publisher.publish(published)
                        logger.info("\(stream)/\(groupName): forwarded \(record.eventType) -> \(published.eventType) (\(published.eventId))")
                    }
                } catch {
                    // Keep going: a later rule may be perfectly healthy, and a
                    // parked record is never redelivered — this is its only chance.
                    failures.append(error)
                }
            }
            switch ForwardingDisposition(forAnyOf: failures) {
            case nil:
                try await subscription.ack(readEvents: event)
            case .retry:
                // Routine under at-least-once — a healthy redelivery path, not
                // an operator page. `.park` below is the one that needs eyes.
                logger.warning("\(stream)/\(groupName): forwarding failed (\(failures.count) rule failure(s)), will retry: \(failures)")
                try await subscription.nack(readEvents: event, action: .retry, reason: "\(failures)")
            case .park:
                logger.error("\(stream)/\(groupName): forwarding permanently failed (\(failures.count) rule failure(s)), parking: \(failures)")
                try await subscription.nack(readEvents: event, action: .park, reason: "\(failures)")
            }
        }
    }

    /// Polls `getInfo()` (`PersistentSubscriptions+Specified.swift:50`) for
    /// `parkedMessageCount`
    /// (`Core/PersistenSubscription/PersistentSubscription.SubscriptionInfo.swift:69`,
    /// `Int64`) every `interval`, surfacing any parked backlog via
    /// `onParkedDetected` (or an error-level log by default). A failed poll
    /// must never take the forwarder down — it's logged and polling continues.
    /// `throws` here is structural, not functional: the body never actually
    /// throws (poll failures are caught and logged below), but the signature
    /// keeps this task's type uniform with `consume()`'s inside the
    /// `withThrowingTaskGroup.addTask { try await … }` in `run()`. Don't
    /// "simplify" it away.
    private func pollParked(every interval: Duration) async throws {
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return }
            do {
                let info = try await client.persistentSubscriptions(stream: stream, group: groupName).getInfo()
                let parked = info.parkedMessageCount
                guard parked > 0 else { continue }
                if let onParkedDetected = monitoring.onParkedDetected {
                    await onParkedDetected(parked)
                } else {
                    logger.error("\(parked) parked message(s) on \(stream)/\(groupName) — those events are NOT reaching the backbone")
                }
            } catch {
                // A failed poll must never take the forwarder down.
                logger.warning("parked-message check failed: \(error)")
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
