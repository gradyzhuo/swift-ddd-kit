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

/// Settings used when a persistent subscription group is created. They apply only at
/// creation — an existing group keeps its server-side settings and checkpoint.
public struct PersistentSubscriptionSettings: Sendable, Equatable {
    public enum StartPosition: Sendable, Equatable { case start, end }

    /// Where a newly created group starts. `.start` (default) is what a read model
    /// needs: a fresh or recreated group rebuilds every snapshot; already-applied
    /// events are no-ops thanks to the stored revision cursor.
    public var startFrom: StartPosition
    /// Required for `$ce-<Category>`/`$et-<Type>` system streams so delivered events
    /// carry the original stream name. Default `true`.
    public var resolveLink: Bool

    public init(startFrom: StartPosition = .start, resolveLink: Bool = true) {
        self.startFrom = startFrom
        self.resolveLink = resolveLink
    }
}

/// Seam over the KurrentDB operations `KurrentStorageCoordinator`/`KurrentProjection`
/// actually call. `LiveEventStoreClient` wraps a real `KurrentDBClient`;
/// `InMemoryEventStoreClient` (KurrentSupportInMemory) needs no server at all.
public protocol EventStoreClient: Sendable {
    /// - Parameter category: The stream's category, as declared by the caller's
    ///   `EventStreamNaming.category` — e.g. `"Order"` for stream `"Order-42"`. Both
    ///   conformances currently ignore this for `$ce-<category>` routing: real KurrentDB's
    ///   `$by_category` standard projection derives category server-side from the stream
    ///   name's segment up to its *first* `-`, not from any value the appending client
    ///   supplies, so `InMemoryEventStoreClient` must derive it the same way to stay a
    ///   faithful test double — a declared category containing its own dash (a
    ///   `.custom("Sales-Order")` rule, say) still only contributes `"Sales"` on a real
    ///   cluster. The parameter is kept for interface symmetry with the caller's naming
    ///   convention and possible future use, not because either conformance trusts it today.
    @discardableResult
    func append(events: [EventData], toStream name: String, category: String, expectedRevision: StreamRevision) async throws -> UInt64?
    func readStream(name: String, from revision: RevisionCursor, resolveLinks: Bool) async throws -> [any RecordedEventLike]
    func deleteStream(name: String, expectedRevision: StreamRevision) async throws
    /// Throws `EventStoreClientError.subscriptionGroupNotFound` — at subscribe time or from `events` — when the group does not exist (or is deleted while subscribed).
    func subscribePersistent(stream: String, group: String) async throws -> any PersistentSubscriptionSession
    /// Creates the persistent subscription group. An already-existing group is
    /// tolerated and left unchanged.
    func ensurePersistentSubscription(stream: String, group: String, settings: PersistentSubscriptionSettings) async throws
    /// Deletes the persistent subscription group. A missing group is tolerated.
    func deletePersistentSubscription(stream: String, group: String) async throws
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
    /// `subscribePersistent` was asked for a `$ce-<category>` stream whose `<category>`
    /// itself contains a `-`. KurrentDB's `$by_category` standard projection always
    /// derives a stream's category from the segment up to its *first* dash, so no stream
    /// can ever be categorized under a name that itself has an embedded dash — the
    /// subscription would never receive anything on a real cluster. Raised at subscribe
    /// time instead of leaving a persistent-subscription runner running forever with no
    /// deliveries.
    case unroutableCategory(stream: String)
    /// The persistent subscription group does not exist — never created, or deleted
    /// (e.g. the KurrentDB instance was recreated). Raised by `subscribePersistent`
    /// or from a session's `events` when the group disappears mid-subscription.
    case subscriptionGroupNotFound(stream: String, group: String)
}

/// Shared by both `EventStoreClient` conformances so `$ce-<category>` handling stays
/// consistent between them.
public enum CategoryProjectionStream {
    /// `"$ce-<category>"` → `"<category>"`, or `nil` if `stream` isn't a
    /// category-projection stream at all.
    public static func category(forStream stream: String) -> String? {
        let prefix = "$ce-"
        guard stream.hasPrefix(prefix) else { return nil }
        return String(stream.dropFirst(prefix.count))
    }
}
