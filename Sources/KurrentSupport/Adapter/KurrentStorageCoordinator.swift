import DDDCore
import EventSourcing
import KurrentDB
import Foundation
import Logging

fileprivate struct EventWrapped: Sendable {
    let event: any DomainEvent
    let revision: UInt64
}

public final class KurrentStorageCoordinator<
    StreamNaming: EventStreamNaming,
    Metadata: EventMetadata
>: EventStore {
    let logger = Logger(label: "KurrentStorageCoordinator")
    let eventMapper: any EventTypeMapper
    let client: any EventStoreClient

    public init(client: any EventStoreClient, eventMapper: any EventTypeMapper) {
        self.eventMapper = eventMapper
        self.client = client
    }

    /// Convenience initializer for the common case of a real KurrentDB connection.
    /// Wraps `client` in a `LiveEventStoreClient` internally.
    public convenience init(client: KurrentDBClient, eventMapper: any EventTypeMapper) {
        self.init(client: LiveEventStoreClient(client: client), eventMapper: eventMapper)
    }

    /// Inside `withUnitOfWork(_:)` the events are staged in the unit of work's backend
    /// instead of written, and the returned revision is the one the last of them is predicted
    /// to get when the unit of work commits.
    public func append(
        events: [any DDDCore.DomainEvent],
        byId id: String,
        version: UInt64?,
        metadata: Metadata?
    ) async throws -> UInt64? {
        guard !events.isEmpty else { return nil }
        let streamName = StreamNaming.getStreamName(id: id)
        // KurrentDB revisions are Int64, so this can never match; the server rejects it with an internal error.
        // `actual` is the last readable revision: a truncated or soft-deleted stream reports nil.
        if let version, version > UInt64(Int64.max) {
            let actual: UInt64?
            do {
                actual = try await client.readStream(name: streamName, from: .start, resolveLinks: false).last?.revision
            } catch EventStoreClientError.streamNotFound {
                actual = nil
            } catch KurrentError.resourceDeleted {
                throw DDDError.streamPurged(id: id)
            }
            throw DDDError.commitConflict(id: id, expected: version, actual: actual)
        }
        let encoded = try encodeForKurrent(events: events, metadata: metadata)
        // A `nil` version means the aggregate has never been persisted —
        // expect `.noStream` so a concurrent/duplicate create collides
        // with the existing stream instead of silently succeeding under
        // `.any` (which skips the concurrency check altogether).
        let expectedRevision: StreamRevision = version.map { .at($0) } ?? .noStream
        if let work = UnitOfWork.current {
            return try stage(
                encoded.events,
                metadataBytes: encoded.metadataBytes,
                id: id,
                streamName: streamName,
                expectedRevision: expectedRevision,
                in: work
            )
        }
        do {
            return try await client.append(events: encoded.events, toStream: streamName, category: StreamNaming.category, expectedRevision: expectedRevision)
        } catch {
            throw mapSingleStreamAppendError(error, id: id, expected: version)
        }
    }

    /// Stages `events` in `work`'s backend instead of writing them, and returns the revision
    /// the last of them is predicted to get.
    ///
    /// - Throws: `DDDError.operationNotAllow(operation: "save", …)` when AppendRecords cannot
    ///   carry the events' metadata; the backend's errors otherwise.
    private func stage(
        _ events: [EventData],
        metadataBytes: Data?,
        id: String,
        streamName: String,
        expectedRevision: StreamRevision,
        in work: UnitOfWork
    ) throws -> UInt64 {
        // A unit of work of more than one stream commits through AppendRecords, whose records
        // carry metadata as properties, not raw bytes. How many streams it writes is not
        // known yet, so every save checks, and fails now instead of at the commit.
        if metadataBytes != nil {
            do {
                for event in events {
                    _ = try EventRecord(eventData: event)
                }
            } catch {
                throw DDDError.operationNotAllow(
                    operation: "save",
                    reason: "Metadata cannot be carried by AppendRecords: \(error)"
                )
            }
        }
        return try backend(of: work).stage(
            id: id,
            stream: streamName,
            category: StreamNaming.category,
            expectedRevision: expectedRevision,
            events: events
        )
    }

    /// The backend `work` commits through, created for this coordinator's client on first use.
    ///
    /// - Throws: `DDDError.operationNotAllow` when `work` already commits through the backend
    ///   of a client with another identity, or has ended.
    private func backend(of work: UnitOfWork) throws -> KurrentUnitOfWorkBackend {
        try work.backend(KurrentUnitOfWorkBackend.self, identity: client.identity) {
            KurrentUnitOfWorkBackend(client: client)
        }
    }

    /// Inside `withUnitOfWork(_:)` the events the unit of work has staged for the stream
    /// follow the server's, also when the server has no such stream or it was purged. They
    /// are numbered with the revisions they are predicted to get, and `latestRevision` is the
    /// last staged one, even when the mapper leaves that event out.
    public func fetchEvents(byId id: String) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)? {
        let streamName = StreamNaming.getStreamName(id: id)
        let serverRecords = try await readRecords(of: streamName, from: .start)
        let staged = try stagedRecords(of: streamName)

        let eventWrappers = mapRecords((serverRecords ?? []) + staged)

        guard let lastMappedRevision = eventWrappers.last?.revision else {
            return nil
        }

        // Stream order is revision order; do not re-sort. The last staged revision is the
        // tail the next save in the unit of work must expect.
        return (events: eventWrappers.map(\.event), latestRevision: staged.last?.revision ?? lastMappedRevision)
    }

    /// Inside `withUnitOfWork(_:)` the staged events after `revision` follow the server's, as
    /// in `fetchEvents(byId:)`, and `latestRevision` is the last staged one whenever the unit
    /// of work has staged events for the stream.
    public func fetchEvents(byId id: String, afterRevision revision: UInt64) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)? {
        let streamName = StreamNaming.getStreamName(id: id)
        let serverRecords = try await readRecords(of: streamName, from: .specified(revision + 1))
        let staged = try stagedRecords(of: streamName)
        guard serverRecords != nil || !staged.isEmpty else {
            return nil
        }

        // The server's records already start after `revision`; the staged ones need the filter.
        let eventWrappers = mapRecords((serverRecords ?? []) + staged.filter { $0.revision > revision })

        let latestRevision = staged.last?.revision ?? eventWrappers.last?.revision ?? revision
        return (events: eventWrappers.map(\.event), latestRevision: latestRevision)
    }

    /// The server's records of `streamName` from `cursor` on, or `nil` when the stream does
    /// not exist or was purged.
    private func readRecords(of streamName: String, from cursor: RevisionCursor) async throws -> [any RecordedEventLike]? {
        do {
            return try await client.readStream(name: streamName, from: cursor, resolveLinks: true)
        } catch EventStoreClientError.streamNotFound {
            logger.warning("Skip an error happened, stream not found: \(streamName)")
            return nil
        } catch KurrentError.resourceDeleted {
            // Tombstoned by `purge`.
            return nil
        } catch {
            logger.error("The error happened when fetching events: \(error)")
            throw error
        }
    }

    /// The events the current unit of work has staged for `streamName`, as records numbered
    /// with the revisions they are predicted to get; empty outside a unit of work or when
    /// nothing is staged for the stream.
    ///
    /// The numbering starts from the staged batch's own expected revision, never from the
    /// last record read from the server: a record the mapper skips, or an empty
    /// `afterRevision` window, would make that one wrong.
    private func stagedRecords(of streamName: String) throws -> [any RecordedEventLike] {
        guard let work = UnitOfWork.current,
              let staged = try backend(of: work).stagedEvents(stream: streamName)
        else {
            return []
        }
        return staged.events.enumerated().map { offset, event in
            StagedRecordedEvent(eventData: event, revision: staged.firstRevision + UInt64(offset), streamName: streamName)
        }
    }

    /// Maps `records` in order through `eventMapper`, leaving out those it maps to `nil` and,
    /// with a warning, those it throws on.
    private func mapRecords(_ records: [any RecordedEventLike]) -> [EventWrapped] {
        records.reduce(into: []) {
            do {
                guard let event = try eventMapper.mapping(eventData: $1) else {
                    return
                }
                $0.append(.init(event: event, revision: $1.revision))
            } catch {
                logger.warning("skipped event cause error happened. error: \(error)")
            }
        }
    }

    /// Tombstones the stream: the id can never be written again, even if it never
    /// existed. KurrentDB keeps the data until a scavenge.
    ///
    /// - Throws: `DDDError.operationNotAllow(operation: "purge", …)` inside
    ///   `withUnitOfWork(_:)`, without touching the stream.
    public func purge(byId id: String) async throws {
        guard UnitOfWork.current == nil else {
            throw DDDError.operationNotAllow(operation: "purge", reason: "not allowed inside a unit of work")
        }
        let streamName = StreamNaming.getStreamName(id: id)
        do {
            try await client.tombstoneStream(name: streamName)
        } catch KurrentError.resourceDeleted {
            // Already purged.
        }
    }
}

/// Inside `withUnitOfWork(_:)` the coordinator stages its appends in the unit of work instead
/// of writing them, so repositories over it may save there.
extension KurrentStorageCoordinator: UnitOfWorkParticipant {}
