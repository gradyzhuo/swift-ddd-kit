//
//  EventStoreClient.swift
//  KurrentSupport
//
//  Narrow seam wrapping exactly the KurrentDB operations `KurrentStorageCoordinator`
//  and `KurrentProjection`'s runners call. `RecordedEvent`/`ReadEvent`/`Streams`/
//  `PersistentSubscriptions` (swift-kurrentdb) cannot be conformed to or constructed
//  from outside that package, so this seam is expressed in terms of `EventData`
//  (already public/constructible) plus its own small DTOs instead. `LiveEventStoreClient`
//  (this target) and `InMemoryEventStoreClient` (KurrentSupportInMemory target) are the
//  two conformances.
//

import Foundation
import KurrentDB

/// A single stored/delivered event, decoupled from the concrete KurrentDB `RecordedEvent`.
public protocol RecordedEventLike: Sendable {
    var id: UUID { get }
    var eventType: String { get }
    var revision: UInt64 { get }
    var customMetadata: Data { get }
    /// Name of the stream this event was originally appended to — e.g. `"Order-42"`,
    /// even when delivered via a resolved `$ce-Order` category-projection link.
    var streamName: String { get }
    func decode<T: Decodable>(to type: T.Type) throws -> T?
}

/// An event pushed by a persistent-subscription session, with its redelivery count.
public struct SubscriptionDelivery: Sendable {
    public let event: any RecordedEventLike
    public let retryCount: Int

    public init(event: any RecordedEventLike, retryCount: Int) {
        self.event = event
        self.retryCount = retryCount
    }
}

/// An active persistent-subscription session — the seam's analog of
/// `PersistentSubscriptions.Subscription`.
public protocol PersistentSubscriptionSession: Sendable {
    var events: AsyncThrowingStream<SubscriptionDelivery, Error> { get }
    func ack(_ deliveries: [SubscriptionDelivery]) async throws
    func nack(_ deliveries: [SubscriptionDelivery], action: KurrentProjection.NackAction, reason: String) async throws
}

/// Seam over the KurrentDB operations `KurrentStorageCoordinator`/`KurrentProjection`
/// actually call. `LiveEventStoreClient` wraps a real `KurrentDBClient`;
/// `InMemoryEventStoreClient` (KurrentSupportInMemory) needs no server at all.
public protocol EventStoreClient: Sendable {
    /// - Parameter category: The stream's category, exactly as declared by the caller's
    ///   `EventStreamNaming.category` — e.g. `"Order"` for stream `"Order-42"`. Passed
    ///   explicitly rather than re-derived from `name` by splitting on `"-"`: a category
    ///   that itself contains a dash (a `.custom("Sales-Order")` rule, say) would make a
    ///   naive first-dash split disagree with the category a `$ce-Sales-Order` subscriber
    ///   asks for. `LiveEventStoreClient` ignores this — real KurrentDB derives category
    ///   server-side regardless of what's passed. `InMemoryEventStoreClient` uses it as
    ///   the ground truth for routing to `$ce-<category>` persistent-subscription sessions.
    @discardableResult
    func append(events: [EventData], toStream name: String, category: String, expectedRevision: StreamRevision) async throws -> UInt64?
    func readStream(name: String, from revision: RevisionCursor, resolveLinks: Bool) async throws -> [any RecordedEventLike]
    func deleteStream(name: String, expectedRevision: StreamRevision) async throws
    func subscribePersistent(stream: String, group: String) async throws -> any PersistentSubscriptionSession
}

/// Errors raised by an `EventStoreClient` conformance, independent of any
/// concrete backend's own error taxonomy (e.g. swift-kurrentdb's `KurrentError`).
public enum EventStoreClientError: Error, Sendable, Equatable {
    /// The named stream has never been written to (or was deleted).
    case streamNotFound
    /// `append`'s `expectedRevision` did not match the stream's actual current revision.
    case wrongExpectedRevision(current: UInt64?)
    /// `subscribePersistent` was asked for a system-projection stream this conformance
    /// doesn't emulate (e.g. `$et-<EventType>`, `$all`) — only `$ce-<Category>` is understood.
    /// Raised instead of silently returning a session that will never receive anything.
    case unsupportedProjection(stream: String)
}
