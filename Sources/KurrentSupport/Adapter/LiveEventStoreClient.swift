//
//  LiveEventStoreClient.swift
//  KurrentSupport
//
//  The production `EventStoreClient` conformance — a thin pass-through to a
//  real `KurrentDBClient`. Extracted from `KurrentStorageCoordinator`/
//  `KurrentProjection` verbatim; behavior is unchanged from before the seam existed.
//

import EventSourcing
import Foundation
import KurrentDB
import Synchronization

extension RecordedEvent: RecordedEventLike {
    public var streamName: String { streamIdentifier.name }
}

public struct LiveEventStoreClient: EventStoreClient {
    let client: KurrentDBClient

    public init(client: KurrentDBClient) {
        self.client = client
    }

    /// The wrapped `KurrentDBClient`'s identity: seams over one `KurrentDBClient` commit
    /// together in a unit of work; two `KurrentDBClient` instances never do, even when
    /// they connect to the same cluster.
    public var identity: ObjectIdentifier { ObjectIdentifier(client) }

    public func append(
        events: [EventData],
        toStream name: String,
        category: String,
        expectedRevision: StreamRevision
    ) async throws -> UInt64? {
        // `category` is unused here — real KurrentDB derives a stream's category
        // server-side from its own algorithm, regardless of what we pass. It only
        // matters to `InMemoryEventStoreClient`, which has no server to ask.
        let stream = client.streams(specified: name)
        let response = try await stream.append(events: events) {
            $0.expectedRevision = expectedRevision
        }
        return response.currentRevision
    }

    public func readStream(
        name: String,
        from revision: RevisionCursor,
        resolveLinks: Bool
    ) async throws -> [any RecordedEventLike] {
        do {
            let stream = client.streams(specified: name)
            let responses = try await stream.read {
                $0.direction = .forward
                $0.revision = revision
                $0.resolveLinks = resolveLinks
            }
            var records: [RecordedEvent] = []
            for try await response in responses {
                records.append(try response.event.record)
            }
            return records
        } catch KurrentError.resourceNotFound {
            throw EventStoreClientError.streamNotFound
        }
    }

    public func deleteStream(name: String, expectedRevision: StreamRevision) async throws {
        _ = try await client.streams(specified: name).delete {
            $0.expectedRevision = expectedRevision
        }
    }

    public func tombstoneStream(name: String) async throws {
        _ = try await client.streams(specified: name).tombstone {
            $0.expectedRevision = .any
        }
    }

    /// One `appendRecords` call (KurrentDB 26.1+). No extra checks are sent: swift-kurrentdb
    /// derives one from every batch whose expected revision is not `.any`.
    public func appendAtomically(_ batches: [StreamBatch]) async throws -> [StreamBatchResult] {
        let streamEvents = try batches.map { batch in
            StreamEvent(
                stream: batch.stream,
                records: try batch.events.map(EventRecord.init(eventData:)),
                expectedRevision: batch.expectedRevision
            )
        }
        do {
            let response = try await client.multiStreams.appendRecords(events: streamEvents)
            return response.revisions.map {
                StreamBatchResult(stream: $0.streamIdentifier.name, revision: $0.revision)
            }
        } catch {
            guard case let .consistencyViolation(violations) = error,
                  let mapped = Self.mapConsistencyViolations(
                      violations.map { (stream: $0.stream, actualState: $0.actualState) },
                      in: batches
                  )
            else { throw error }
            throw mapped
        }
    }

    /// `actualState` of a tombstoned stream in an `appendRecords` consistency violation
    /// (KurrentDB 26.1 and 26.2; `-5` is soft-deleted, `-1` missing).
    static let tombstonedActualState: Int64 = -6

    /// Maps `appendRecords`' consistency violations to the seam's errors, or returns `nil`
    /// when the caller must rethrow the original `KurrentError` unchanged.
    ///
    /// - A tombstoned stream wins: the server lists tombstones and revision conflicts
    ///   together with no precedence, so the first batch in `batches` order whose stream is
    ///   tombstoned gives `KurrentError.resourceDeleted(resource:)`.
    /// - Otherwise every violation becomes a `StreamConflict` carrying its batch's own
    ///   `expectedRevision`. Any negative `actualState` (missing, soft-deleted) means the
    ///   stream has no current revision, so `current` is `nil`.
    /// - `nil` for an empty list, because `consistencyViolations` is never empty (the
    ///   unit-of-work backend turns it into `DDDError.commitConflict(conflicts:)`, which
    ///   requires at least one conflict), and for a violation on a stream no batch writes,
    ///   rather than inventing its expected revision.
    package static func mapConsistencyViolations(
        _ violations: [(stream: String, actualState: Int64)],
        in batches: [StreamBatch]
    ) -> (any Error)? {
        guard !violations.isEmpty else { return nil }
        let tombstonedStreams = Set(violations.filter { $0.actualState == tombstonedActualState }.map { $0.stream })
        if let tombstoned = batches.first(where: { tombstonedStreams.contains($0.stream) }) {
            return KurrentError.resourceDeleted(resource: tombstoned.stream)
        }
        var conflicts: [StreamConflict] = []
        for violation in violations {
            guard let batch = batches.first(where: { $0.stream == violation.stream }) else { return nil }
            conflicts.append(StreamConflict(
                stream: violation.stream,
                expected: batch.expectedRevision,
                current: violation.actualState < 0 ? nil : UInt64(violation.actualState)
            ))
        }
        return EventStoreClientError.consistencyViolations(conflicts)
    }

    public func subscribePersistent(stream: String, group: String) async throws -> any PersistentSubscriptionSession {
        if let category = CategoryProjectionStream.category(forStream: stream), category.contains("-") {
            // A dashed category can never receive anything on a real cluster (see
            // `EventStoreClientError.unroutableCategory`) — fail now rather than leave
            // the runner subscribed forever with no deliveries.
            throw EventStoreClientError.unroutableCategory(stream: stream)
        }
        do {
            let subscription = try await client.persistentSubscriptions(stream: stream, group: group).subscribe()
            return LiveSubscriptionSession(subscription: subscription, stream: stream, group: group)
        } catch {
            throw Self.mapMissingGroup(error, stream: stream, group: group)
        }
    }

    public func ensurePersistentSubscription(
        stream: String, group: String, settings: PersistentSubscriptionSettings
    ) async throws {
        do {
            try await client.persistentSubscriptions(stream: stream, group: group).create {
                $0.settings.resolveLink = settings.resolveLink
                switch settings.startFrom {
                case .start: $0.revision = .start
                case .end: $0.revision = .end
                }
            }
        } catch {
            // Only already-exists is the steady state (a group created by a prior
            // process start or by the application itself); everything else —
            // connection, auth — must reach the caller.
            guard case .resourceAlreadyExists = error else { throw error }
        }
    }

    public func deletePersistentSubscription(stream: String, group: String) async throws {
        do {
            try await client.persistentSubscriptions(stream: stream, group: group).delete()
        } catch {
            guard case .resourceNotFound = error else { throw error }
        }
    }

    /// KurrentDB answers a subscribe to a group that does not exist with NotFound
    /// ("Subscription group … does not exist"), which swift-kurrentdb maps to
    /// `.resourceNotFound` — same detection as `ContextForwarder.isMissingGroup`.
    ///
    /// Observed live (KurrentDB, integration tests): both a subscribe to a never-created
    /// group and deleting the group while a session is active surface `.resourceNotFound`
    /// from the session's `events`, so both map to `subscriptionGroupNotFound`.
    static func mapMissingGroup(_ error: any Error, stream: String, group: String) -> any Error {
        if let kurrent = error as? KurrentError, case .resourceNotFound = kurrent {
            return EventStoreClientError.subscriptionGroupNotFound(stream: stream, group: group)
        }
        return error
    }
}

/// Bridges a real `PersistentSubscriptions<...>.Subscription` into the seam's
/// `PersistentSubscriptionSession`. Retains each delivered `ReadEvent` (needed
/// to call the real `ack(readEvents:)`/`nack(readEvents:action:reason:)`, which
/// require the original type — `RecordedEvent`'s public initializer doesn't
/// exist, so the seam can't reconstruct one) keyed by the event's id until it's
/// acked or nacked.
final class LiveSubscriptionSession: PersistentSubscriptionSession, Sendable {
    private let subscription: PersistentSubscriptions<SpecifiedPersistentSubscriptionTarget>.Subscription<PersistentSubscription.EventResult>
    private let pendingReadEvents: Mutex<[UUID: ReadEvent]>
    let events: AsyncThrowingStream<SubscriptionDelivery, Error>

    init(subscription: PersistentSubscriptions<SpecifiedPersistentSubscriptionTarget>.Subscription<PersistentSubscription.EventResult>, stream: String, group: String) {
        self.subscription = subscription
        self.pendingReadEvents = Mutex<[UUID: ReadEvent]>([:])

        let (eventStream, continuation) = AsyncThrowingStream<SubscriptionDelivery, Error>.makeStream()
        events = eventStream

        let bridgeTask = Task {
            do {
                for try await result in subscription.events {
                    try Task.checkCancellation()
                    let record = result.event.record
                    self.pendingReadEvents.withLock { $0[record.id] = result.event }
                    continuation.yield(SubscriptionDelivery(event: record, retryCount: Int(result.retryCount)))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: LiveEventStoreClient.mapMissingGroup(error, stream: stream, group: group))
            }
        }
        // The real subscription is only observed by this producer task — if the
        // consumer stops iterating `events` (runner cancelled/returns) without this,
        // the task keeps pulling from the live gRPC subscription forever, holding
        // its connection and session open.
        continuation.onTermination = { _ in bridgeTask.cancel() }
    }

    func ack(_ deliveries: [SubscriptionDelivery]) async throws {
        let readEvents = takeReadEvents(for: deliveries)
        guard !readEvents.isEmpty else { return }
        try await subscription.ack(readEvents: readEvents)
    }

    func nack(_ deliveries: [SubscriptionDelivery], action: KurrentProjection.NackAction, reason: String) async throws {
        let readEvents = takeReadEvents(for: deliveries)
        guard !readEvents.isEmpty else { return }
        let kurrentAction: PersistentSubscriptions<SpecifiedPersistentSubscriptionTarget>.Nack.Action = switch action {
            case .retry: .retry
            case .skip: .skip
            case .park: .park
            case .stop: .stop
        }
        try await subscription.nack(readEvents: readEvents, action: kurrentAction, reason: reason)
    }

    private func takeReadEvents(for deliveries: [SubscriptionDelivery]) -> [ReadEvent] {
        pendingReadEvents.withLock { pending in
            deliveries.compactMap { pending.removeValue(forKey: $0.event.id) }
        }
    }
}
