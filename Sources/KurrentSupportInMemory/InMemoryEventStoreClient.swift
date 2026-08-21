//
//  InMemoryEventStoreClient.swift
//  KurrentSupportInMemory
//
//  An `EventStoreClient` that needs no KurrentDB server at all — for unit tests
//  that exercise `KurrentStorageCoordinator`/`KurrentProjection.PersistentSubscriptionRunner`
//  end to end without a live cluster.
//
//  Styled after `EventSourcing`'s `InMemoryStorageCoordinator`, one layer lower:
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
        /// The category the caller declared for this stream (`EventStreamNaming.category`),
        /// passed in at append time rather than re-derived from `streamName` — see the
        /// doc comment on `EventStoreClient.append`.
        let category: String
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
    private var subscriptions: [SubscriptionKey: InMemorySubscriptionSession] = [:]
    private var globalSequenceCounter: UInt64 = 0

    private let deliveryDelay: Duration

    /// - Parameter deliveryDelay: `.zero` (default) delivers to persistent-subscription
    ///   sessions synchronously as part of `append` — by the time `append` returns,
    ///   any running `PersistentSubscriptionRunner` has already processed the event,
    ///   so tests need no polling/sleep. Pass a non-zero delay to deliberately exercise
    ///   the eventual-consistency path instead.
    public init(deliveryDelay: Duration = .zero) {
        self.deliveryDelay = deliveryDelay
    }

    // MARK: - EventStoreClient

    @discardableResult
    public func append(
        events: [EventData],
        toStream name: String,
        category: String,
        expectedRevision: StreamRevision
    ) async throws -> UInt64? {
        var existing = streams[name] ?? []
        let lastRevision = existing.last?.revision

        switch expectedRevision {
        case .any:
            break
        case .noStream:
            guard existing.isEmpty else {
                throw EventStoreClientError.wrongExpectedRevision(current: lastRevision)
            }
        case .streamExists:
            guard !existing.isEmpty else {
                throw EventStoreClientError.wrongExpectedRevision(current: nil)
            }
        case let .at(expected):
            guard lastRevision == expected else {
                throw EventStoreClientError.wrongExpectedRevision(current: lastRevision)
            }
        }

        var nextRevision = lastRevision.map { $0 + 1 } ?? 0
        var stored: [StoredEvent] = []
        for event in events {
            globalSequenceCounter += 1
            stored.append(StoredEvent(
                id: event.id,
                eventType: event.eventType,
                revision: nextRevision,
                customMetadata: event.customMetadata ?? Data(),
                streamName: name,
                category: category,
                payloadData: try event.payload.data,
                globalSequence: globalSequenceCounter
            ))
            nextRevision += 1
        }

        existing.append(contentsOf: stored)
        streams[name] = existing

        deliverToSubscriptions(stored, streamName: name, category: category)

        return existing.last?.revision
    }

    public func readStream(
        name: String,
        from revision: RevisionCursor,
        resolveLinks: Bool
    ) async throws -> [any RecordedEventLike] {
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
        if case .streamExists = expectedRevision, streams[name] == nil {
            throw EventStoreClientError.streamNotFound
        }
        streams.removeValue(forKey: name)
    }

    public func subscribePersistent(stream target: String, group: String) async throws -> any PersistentSubscriptionSession {
        // `$ce-<Category>` is the only system-projection convention this fake
        // understands (it's the only one `KurrentProjection` ever subscribes to).
        // Anything else starting with `$` — `$et-<EventType>`, `$all`, a raw
        // `$by_category`-style name, etc. — would otherwise create a session
        // that looks fine but silently never receives anything. Fail loudly
        // instead: a hung test with a clear error beats a hung test with none.
        if target.hasPrefix("$"), categoryProjectionName(target) == nil {
            throw EventStoreClientError.unsupportedProjection(stream: target)
        }

        let key = SubscriptionKey(stream: target, group: group)
        if let existing = subscriptions[key] {
            return existing
        }

        let session = InMemorySubscriptionSession()
        subscriptions[key] = session

        // Deliberate design choice: replay everything already stored, in commit
        // order, before switching to live tail delivery — real KurrentDB's start
        // position is a server-side setting this codebase never configures, and
        // replay-from-start is what makes "seed events, then subscribe" tests
        // deterministic with no sleeps.
        for stored in matchingStoredEvents(for: target) {
            session.deliver(stored)
        }

        return session
    }

    // MARK: - Category / subscription routing

    private func matchingStoredEvents(for target: String) -> [StoredEvent] {
        if let category = categoryProjectionName(target) {
            return streams
                .flatMap(\.value)
                .filter { $0.category == category }
                .sorted { $0.globalSequence < $1.globalSequence }
        }
        return streams[target] ?? []
    }

    /// `"$ce-<Category>"` → `"<Category>"` (kept whole, dashes and all — a category
    /// name may itself contain `"-"`), or `nil` if `target` isn't a category-projection stream.
    private func categoryProjectionName(_ target: String) -> String? {
        let prefix = "$ce-"
        guard target.hasPrefix(prefix) else { return nil }
        return String(target.dropFirst(prefix.count))
    }

    private func deliverToSubscriptions(_ newEvents: [StoredEvent], streamName: String, category: String) {
        guard !newEvents.isEmpty else { return }
        for (key, session) in subscriptions {
            let matchesExactStream = key.stream == streamName
            let matchesCategory = key.stream == "$ce-\(category)"
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
