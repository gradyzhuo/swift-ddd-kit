//
//  InMemoryEventStoreClient.swift
//  KurrentSupportInMemory
//
//  An `EventStoreClient` that needs no KurrentDB server at all — for unit tests
//  that exercise `KurrentStorageCoordinator`/`KurrentProjection.PersistentSubscriptionRunner`
//  end to end without a live cluster.
//
//  Styled after `EventSourcing`'s `InMemoryEventStore`, one layer lower:
//  this fakes KurrentDB's own append/read/delete + persistent-subscription push,
//  not swift-ddd-kit's abstract `EventStore`.
//

import Foundation
import KurrentSupport
import KurrentDB
import Synchronization

public actor InMemoryEventStoreClient: EventStoreClient {

    private struct StoredEvent: RecordedEventLike {
        let id: UUID
        let eventType: String
        let revision: UInt64
        let customMetadata: Data
        let streamName: String
        /// The category as KurrentDB's own `$by_category` standard projection would
        /// derive it: the segment of `streamName` up to (not including) its first `-`,
        /// or `nil` for a name without one, which that projection leaves uncategorized.
        /// Deliberately *not* the caller-declared `EventStreamNaming.category` — a
        /// custom category with its own dash (e.g. `.custom("Sales-Order")`, stream
        /// `"Sales-Order-1"`) still only contributes `"Sales"` to the real `$ce-Sales`
        /// stream server-side. Routing here must reproduce that, or tests against
        /// this fake would pass for a `$ce-` subscription that never fires for real.
        let category: String?
        let payloadData: Data
        /// Global append order across all streams — the only way to interleave
        /// events from different aggregate streams in commit order when replaying
        /// a synthesized `$ce-<Category>` feed.
        let globalSequence: UInt64

        func decode<T: Decodable>(to type: T.Type) throws -> T? {
            try JSONDecoder().decode(T.self, from: payloadData)
        }
    }

    private struct SubscriptionKey: Hashable {
        let stream: String
        let group: String
    }

    private var streams: [String: [StoredEvent]] = [:]
    /// The tail revision of each soft-deleted stream that has not been written since.
    /// Like a real cluster, such a stream reads as not found, accepts a write expecting
    /// no stream, its old tail or any revision, and numbers that write from tail + 1.
    private var deletedTails: [String: UInt64] = [:]
    /// Names tombstoned via `tombstoneStream`. Like a real cluster, every later
    /// read/append/delete/tombstone of them throws `KurrentError.resourceDeleted`.
    private var tombstoned: Set<String> = []
    private var subscriptions: [SubscriptionKey: InMemorySubscriptionSession] = [:]
    private var globalSequenceCounter: UInt64 = 0

    private var groupSettings: [SubscriptionKey: PersistentSubscriptionSettings] = [:]
    private let deliveryDelay: Duration
    private let requireExplicitGroups: Bool

    /// - Parameter requireExplicitGroups: `false` (default) creates a group on first
    ///   subscribe, replaying from the start — the pre-existing behavior. `true` makes
    ///   `subscribePersistent` throw `.subscriptionGroupNotFound` for a group that was
    ///   never ensured (or was deleted), mirroring a real cluster — use it to test
    ///   group creation/recreation logic.
    /// - Parameter deliveryDelay: `.zero` (default) delivers to persistent-subscription
    ///   sessions synchronously as part of `append` — by the time `append` returns,
    ///   any running `PersistentSubscriptionRunner` has already processed the event,
    ///   so tests need no polling/sleep. Pass a non-zero delay to deliberately exercise
    ///   the eventual-consistency path instead.
    public init(deliveryDelay: Duration = .zero, requireExplicitGroups: Bool = false) {
        self.deliveryDelay = deliveryDelay
        self.requireExplicitGroups = requireExplicitGroups
    }

    // MARK: - EventStoreClient

    /// This instance's identity: every `InMemoryEventStoreClient` is a store of its own.
    nonisolated public var identity: ObjectIdentifier { ObjectIdentifier(self) }

    @discardableResult
    public func append(
        events: [EventData],
        toStream name: String,
        category: String,
        expectedRevision: StreamRevision
    ) async throws -> UInt64? {
        // `category` (the caller-declared `EventStreamNaming.category`) is ignored for
        // routing, same as `LiveEventStoreClient` ignores it — see `EventStoreClient.append`'s
        // doc comment. `$ce-<Category>` routing must match what real KurrentDB derives
        // from the stream name itself.
        if tombstoned.contains(name) { throw KurrentError.resourceDeleted(resource: name) }
        let existing = streams[name] ?? []

        // KurrentDB de-duplicates by event id: resending a batch that is already
        // stored right after the expected position succeeds without writing.
        if let replayed = Self.idempotentRevision(of: events, in: existing, expected: expectedRevision) {
            return replayed
        }

        try checkExpectedRevision(expectedRevision, ofStream: name)

        let stored = store(try Self.encodePayloads(of: events), inStream: name)
        deliverToSubscriptions(stored, streamName: name, category: Self.systemCategory(forStreamName: name))

        return streams[name]?.last?.revision
    }

    public func readStream(
        name: String,
        from revision: RevisionCursor,
        resolveLinks: Bool
    ) async throws -> [any RecordedEventLike] {
        if tombstoned.contains(name) { throw KurrentError.resourceDeleted(resource: name) }
        guard let entry = streams[name] else {
            throw EventStoreClientError.streamNotFound
        }
        switch revision {
        case .start:
            return entry
        case .end:
            // Unused by any call site in this codebase today — reads always
            // start `.start` or `.specified(_:)`.
            return []
        case let .specified(from):
            return entry.filter { $0.revision >= from }
        }
    }

    public func deleteStream(name: String, expectedRevision: StreamRevision) async throws {
        if tombstoned.contains(name) { throw KurrentError.resourceDeleted(resource: name) }
        let existing = streams[name]
        let tail = existing?.last?.revision ?? deletedTails[name]

        switch expectedRevision {
        case .any:
            break
        case .noStream:
            guard existing == nil else {
                throw EventStoreClientError.wrongExpectedRevision(current: tail)
            }
        case .streamExists:
            guard existing == nil else { break }
            guard deletedTails[name] == nil else { throw KurrentError.resourceDeleted(resource: name) }
            throw EventStoreClientError.streamNotFound
        case let .at(expected):
            guard tail == expected else {
                throw EventStoreClientError.wrongExpectedRevision(current: tail)
            }
        }

        streams.removeValue(forKey: name)
        if let tail { deletedTails[name] = tail }
    }

    public func tombstoneStream(name: String) async throws {
        guard !tombstoned.contains(name) else { throw KurrentError.resourceDeleted(resource: name) }
        tombstoned.insert(name)
        streams.removeValue(forKey: name)
        deletedTails.removeValue(forKey: name)
    }

    /// Checks every batch before writing any, with the live seam's precedence: the first
    /// tombstoned stream in batch order throws `resourceDeleted` before any conflict is
    /// reported. Then writes the batches in order, each stream continuing from its own tail
    /// and the global sequence continuing across batches, and delivers to subscriptions
    /// only once every batch is stored.
    public func appendAtomically(_ batches: [StreamBatch]) async throws -> [StreamBatchResult] {
        // KurrentDB answers a resent `appendRecords` (same record ids) with the original
        // revisions and writes nothing. Only a request in which every batch is a resend is
        // modelled: the server's answer to a partial resend is unverified, so that falls
        // through to the ordinary checks below and conflicts.
        let replayed = batches.compactMap { batch in
            Self.idempotentRevision(of: batch.events, in: streams[batch.stream] ?? [], expected: batch.expectedRevision)
                .map { StreamBatchResult(stream: batch.stream, revision: $0) }
        }
        if replayed.count == batches.count { return replayed }

        if let tombstonedBatch = batches.first(where: { tombstoned.contains($0.stream) }) {
            throw KurrentError.resourceDeleted(resource: tombstonedBatch.stream)
        }
        var conflicts: [StreamConflict] = []
        for batch in batches {
            do {
                try checkExpectedRevision(batch.expectedRevision, ofStream: batch.stream)
            } catch EventStoreClientError.wrongExpectedRevision(let current) {
                conflicts.append(StreamConflict(stream: batch.stream, expected: batch.expectedRevision, current: current))
            }
        }
        guard conflicts.isEmpty else { throw EventStoreClientError.consistencyViolations(conflicts) }

        // Encode every batch before storing any, so a payload that fails to encode leaves
        // every stream untouched.
        let encodedBatches = try batches.map { (stream: $0.stream, events: try Self.encodePayloads(of: $0.events)) }
        let storedBatches = encodedBatches.map { (stream: $0.stream, events: store($0.events, inStream: $0.stream)) }
        for batch in storedBatches {
            deliverToSubscriptions(batch.events, streamName: batch.stream, category: Self.systemCategory(forStreamName: batch.stream))
        }
        return storedBatches.compactMap { batch in
            batch.events.last.map { StreamBatchResult(stream: batch.stream, revision: $0.revision) }
        }
    }

    public func subscribePersistent(stream target: String, group: String) async throws -> any PersistentSubscriptionSession {
        try validateSubscriptionTarget(target)
        let key = SubscriptionKey(stream: target, group: group)
        if groupSettings[key] == nil {
            guard !requireExplicitGroups else {
                throw EventStoreClientError.subscriptionGroupNotFound(stream: target, group: group)
            }
            try await ensurePersistentSubscription(stream: target, group: group, settings: .init())
        }
        // `ensure` always creates the session alongside the group.
        return subscriptions[key]!
    }

    public func ensurePersistentSubscription(
        stream target: String, group: String, settings: PersistentSubscriptionSettings
    ) async throws {
        try validateSubscriptionTarget(target)
        let key = SubscriptionKey(stream: target, group: group)
        guard groupSettings[key] == nil else { return }
        groupSettings[key] = settings

        let session = InMemorySubscriptionSession()
        subscriptions[key] = session
        // `.start`: replay everything already stored, in commit order, before live
        // tail delivery — makes "seed events, then subscribe" tests deterministic.
        // `.end`: only events appended from now on.
        if settings.startFrom == .start {
            for stored in matchingStoredEvents(for: target) {
                session.deliver(stored)
            }
        }
    }

    public func deletePersistentSubscription(stream target: String, group: String) async throws {
        let key = SubscriptionKey(stream: target, group: group)
        groupSettings.removeValue(forKey: key)
        subscriptions.removeValue(forKey: key)?
            .end(throwing: EventStoreClientError.subscriptionGroupNotFound(stream: target, group: group))
    }

    /// Test helper: whether the group currently exists.
    public func persistentSubscriptionExists(stream: String, group: String) -> Bool {
        groupSettings[SubscriptionKey(stream: stream, group: group)] != nil
    }

    private func validateSubscriptionTarget(_ target: String) throws {
        // `$ce-<Category>` is the only system-projection convention this fake
        // understands (it's the only one `KurrentProjection` ever subscribes to).
        // Anything else starting with `$` — `$et-<EventType>`, `$all`, a raw
        // `$by_category`-style name, etc. — would otherwise create a session
        // that looks fine but silently never receives anything. Fail loudly
        // instead: a hung test with a clear error beats a hung test with none.
        guard target.hasPrefix("$") else { return }
        guard let category = categoryProjectionName(target) else {
            throw EventStoreClientError.unsupportedProjection(stream: target)
        }
        // A category containing its own dash can never be produced by real
        // KurrentDB's `$by_category` projection (see `systemCategory(forStreamName:)`),
        // so no stream will ever be routed here — fail now instead of a session
        // that silently never receives anything.
        guard !category.contains("-") else {
            throw EventStoreClientError.unroutableCategory(stream: target)
        }
    }

    // MARK: - Storage

    /// The expected-revision check `append` and `appendAtomically` share. Throws
    /// `wrongExpectedRevision` with the stream's current revision (`nil`: no stream). A
    /// soft-deleted stream counts as no stream for `.noStream` and keeps its tail for
    /// `.at(_:)`; `.streamExists` on it throws `resourceDeleted`, as the server does.
    private func checkExpectedRevision(_ expected: StreamRevision, ofStream name: String) throws {
        let stored = streams[name] ?? []
        let tail = stored.last?.revision ?? deletedTails[name]
        switch expected {
        case .any:
            break
        case .noStream:
            guard stored.isEmpty else {
                throw EventStoreClientError.wrongExpectedRevision(current: tail)
            }
        case .streamExists:
            guard stored.isEmpty else { break }
            guard deletedTails[name] == nil else { throw KurrentError.resourceDeleted(resource: name) }
            throw EventStoreClientError.wrongExpectedRevision(current: nil)
        case let .at(expected):
            guard tail == expected else {
                throw EventStoreClientError.wrongExpectedRevision(current: tail)
            }
        }
    }

    /// Encodes every payload up front, so storing the events cannot fail part way through.
    private static func encodePayloads(of events: [EventData]) throws -> [(event: EventData, payload: Data)] {
        try events.map { (event: $0, payload: try $0.payload.data) }
    }

    /// Stores `events` after `name`'s tail, numbering their revisions on from it and their
    /// global sequence on from every earlier write, and returns what it stored.
    private func store(_ events: [(event: EventData, payload: Data)], inStream name: String) -> [StoredEvent] {
        let systemCategory = Self.systemCategory(forStreamName: name)
        var existing = streams[name] ?? []
        // A soft-deleted stream is recreated from its old tail + 1.
        var nextRevision = (existing.last?.revision ?? deletedTails.removeValue(forKey: name)).map { $0 + 1 } ?? 0
        var stored: [StoredEvent] = []
        for (event, payload) in events {
            globalSequenceCounter += 1
            stored.append(StoredEvent(
                id: event.id,
                eventType: event.eventType,
                revision: nextRevision,
                customMetadata: event.customMetadata ?? Data(),
                streamName: name,
                category: systemCategory,
                payloadData: payload,
                globalSequence: globalSequenceCounter
            ))
            nextRevision += 1
        }

        existing.append(contentsOf: stored)
        streams[name] = existing
        return stored
    }

    // MARK: - Category / subscription routing

    /// Only `.noStream` and `.at(n)` are covered — the cases the EventStore
    /// contract uses.
    private static func idempotentRevision(
        of events: [EventData], in stored: [StoredEvent], expected: StreamRevision
    ) -> UInt64? {
        guard !events.isEmpty, let first = stored.first?.revision else { return nil }
        // Stored revisions are contiguous but start after the old tail on a stream that
        // was soft-deleted and recreated, so positions are revisions minus the first one.
        let startRevision: UInt64
        switch expected {
        case .noStream: startRevision = 0
        case let .at(revision):
            // A revision at UInt64.max has nothing after it to match.
            guard revision < .max else { return nil }
            startRevision = revision + 1
        case .any, .streamExists: return nil
        }
        // Compare in `UInt64` first: a start beyond the stored records has nothing to
        // match, and converting a huge revision to `Int` would trap.
        guard startRevision >= first, startRevision - first < UInt64(stored.count) else { return nil }
        let start = Int(startRevision - first)
        let end = start + events.count
        guard end <= stored.count else { return nil }
        guard stored[start..<end].map({ $0.id }) == events.map({ $0.id }) else { return nil }
        return stored[end - 1].revision
    }

    private func matchingStoredEvents(for target: String) -> [StoredEvent] {
        if let category = categoryProjectionName(target) {
            return streams
                .flatMap(\.value)
                .filter { $0.category == category }
                .sorted { $0.globalSequence < $1.globalSequence }
        }
        return streams[target] ?? []
    }

    private func categoryProjectionName(_ target: String) -> String? {
        CategoryProjectionStream.category(forStream: target)
    }

    /// KurrentDB's `$by_category` standard projection categorizes a stream by
    /// everything before its *first* `-`, regardless of what the appending code
    /// considers its "real" category. A `.custom("Sales-Order")` category rule
    /// producing stream `"Sales-Order-1"` therefore lands under `$ce-Sales`, not
    /// `$ce-Sales-Order`, on a real cluster — mirrored here so this fake's
    /// `$ce-<Category>` routing matches it.
    /// A name without a dash gets no category, so no `$ce-` stream ever gets its events.
    private static func systemCategory(forStreamName name: String) -> String? {
        guard let dashIndex = name.firstIndex(of: "-") else { return nil }
        return String(name[..<dashIndex])
    }

    private func deliverToSubscriptions(_ newEvents: [StoredEvent], streamName: String, category: String?) {
        guard !newEvents.isEmpty else { return }
        for (key, session) in subscriptions {
            let matchesExactStream = key.stream == streamName
            let matchesCategory = category.map { key.stream == "$ce-\($0)" } ?? false
            guard matchesExactStream || matchesCategory else { continue }

            if deliveryDelay == .zero {
                for event in newEvents { session.deliver(event) }
            } else {
                // One task per (append batch, session), not one per event: an
                // independent `Task` per event gives Swift's scheduler no reason
                // to wake them in the order they were created, so a multi-event
                // append under a non-zero delay could otherwise arrive out of
                // commit order. This keeps events from the *same* append call
                // strictly ordered; ordering across separate append calls under
                // a non-zero delay is still best-effort, not a hard guarantee —
                // documented here rather than silently assumed.
                let delay = deliveryDelay
                let batch = newEvents
                Task {
                    try? await Task.sleep(for: delay)
                    for event in batch { session.deliver(event) }
                }
            }
        }
    }
}

/// Push-based persistent-subscription session — an in-memory queue fed by
/// `InMemoryEventStoreClient.append`/replay, with simplified ack/nack/retry
/// bookkeeping. `.park`/`.stop` drop the delivery rather than modeling a real
/// dead-letter/parked-queue (out of scope for this pass).
private final class InMemorySubscriptionSession: PersistentSubscriptionSession, Sendable {
    let events: AsyncThrowingStream<SubscriptionDelivery, Error>
    private let continuation: AsyncThrowingStream<SubscriptionDelivery, Error>.Continuation

    init() {
        let (stream, continuation) = AsyncThrowingStream<SubscriptionDelivery, Error>.makeStream()
        events = stream
        self.continuation = continuation
    }

    func deliver(_ event: any RecordedEventLike, retryCount: Int = 0) {
        continuation.yield(SubscriptionDelivery(event: event, retryCount: retryCount))
    }

    func end(throwing error: any Error) {
        continuation.finish(throwing: error)
    }

    func ack(_ deliveries: [SubscriptionDelivery]) async throws {
        // Nothing to reconcile — the in-memory queue has no separate pending-delivery
        // ledger to clear; each `deliver` is a one-shot yield.
    }

    func nack(_ deliveries: [SubscriptionDelivery], action: KurrentProjection.NackAction, reason: String) async throws {
        for delivery in deliveries {
            switch action {
            case .retry:
                deliver(delivery.event, retryCount: delivery.retryCount + 1)
            case .skip, .park, .stop:
                break
            }
        }
    }
}
