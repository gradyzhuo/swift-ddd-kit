//
//  LiveEventStoreClient.swift
//  KurrentSupport
//
//  The production `EventStoreClient` conformance — a thin pass-through to a
//  real `KurrentDBClient`. Extracted from `KurrentStorageCoordinator`/
//  `KurrentProjection` verbatim; behavior is unchanged from before the seam existed.
//

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

    public func subscribePersistent(stream: String, group: String) async throws -> any PersistentSubscriptionSession {
        let subscription = try await client.persistentSubscriptions(stream: stream, group: group).subscribe()
        return LiveSubscriptionSession(subscription: subscription)
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

    init(subscription: PersistentSubscriptions<SpecifiedPersistentSubscriptionTarget>.Subscription<PersistentSubscription.EventResult>) {
        self.subscription = subscription
        self.pendingReadEvents = Mutex<[UUID: ReadEvent]>([:])

        let (stream, continuation) = AsyncThrowingStream<SubscriptionDelivery, Error>.makeStream()
        events = stream

        Task {
            do {
                for try await result in subscription.events {
                    let record = result.event.record
                    self.pendingReadEvents.withLock { $0[record.id] = result.event }
                    continuation.yield(SubscriptionDelivery(event: record, retryCount: Int(result.retryCount)))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
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
