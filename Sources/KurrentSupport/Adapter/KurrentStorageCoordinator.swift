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
    let logger: Logger
    let eventMapper: any EventTypeMapper
    let client: any EventStoreClient

    public init(client: any EventStoreClient, eventMapper: any EventTypeMapper) {
        self.eventMapper = eventMapper
        self.client = client
        self.logger = Logger(label: "KurrentStorageCoordinator")
    }

    /// Like `init(client:eventMapper:)`, logging to `logger` instead of a logger labelled
    /// `KurrentStorageCoordinator`.
    package init(client: any EventStoreClient, eventMapper: any EventTypeMapper, logger: Logger) {
        self.eventMapper = eventMapper
        self.client = client
        self.logger = logger
    }

    /// Convenience initializer for the common case of a real KurrentDB connection.
    /// Wraps `client` in a `LiveEventStoreClient` internally.
    public convenience init(client: KurrentDBClient, eventMapper: any EventTypeMapper) {
        self.init(client: LiveEventStoreClient(client: client), eventMapper: eventMapper)
    }

    /// Inside `withUnitOfWork(_:)` the events are staged in the unit of work's backend
    /// instead of written, and the returned revision is the one the last of them is predicted
    /// to get when the unit of work commits.
    ///
    /// - Throws: In and out of a unit of work, when `version` is beyond `Int64.max` (no event
    ///   is sent or staged; the stream is read to report its revision):
    ///   - `DDDError.commitConflict`, or `DDDError.streamPurged` when the stream was purged;
    ///     a client error from that read is rethrown.
    ///
    ///   Outside `withUnitOfWork(_:)`: `DDDError.commitConflict` when the stream is not at
    ///   `version`, `DDDError.streamPurged` for a purged id, and other client errors as thrown.
    ///
    ///   Inside `withUnitOfWork(_:)`:
    ///   - `DDDError.commitConflict` when the unit of work has already staged events for the
    ///     stream and `version` is not the revision the last of them is predicted to get. A
    ///     `version` the server's stream does not match is reported when the unit of work
    ///     commits, as is a save to a purged id.
    ///   - `DDDError.operationNotAllow` when AppendRecords cannot carry `metadata`, when the
    ///     unit of work already commits through a client with another identity, or when it
    ///     has ended.
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
    /// Only writes call it: reads look the backend up without creating or binding one.
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
    ///
    /// - Throws: The client's read errors, inside `withUnitOfWork(_:)` as outside it; a
    ///   missing or purged stream is not one. A read never fails because of the unit of work:
    ///   when it commits through a client with another identity, or has ended, the read
    ///   returns the server's events alone.
    public func fetchEvents(byId id: String) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)? {
        let streamName = StreamNaming.getStreamName(id: id)
        let (serverRecords, staged) = try await serverAndStagedRecords(of: streamName, from: .start)

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
    ///
    /// - Throws: The same errors as `fetchEvents(byId:)`.
    public func fetchEvents(byId id: String, afterRevision revision: UInt64) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)? {
        let streamName = StreamNaming.getStreamName(id: id)
        let (serverRecords, staged) = try await serverAndStagedRecords(of: streamName, from: .specified(revision + 1))
        guard serverRecords != nil || !staged.isEmpty else {
            return nil
        }

        // The server's records already start after `revision`; the staged ones need the filter.
        let eventWrappers = mapRecords((serverRecords ?? []) + staged.filter { $0.revision > revision })

        let latestRevision = staged.last?.revision ?? eventWrappers.last?.revision ?? revision
        return (events: eventWrappers.map(\.event), latestRevision: latestRevision)
    }

    /// The server's records of `streamName` from `cursor` on, `nil` when the stream does not
    /// exist or was purged, and then the records the current unit of work has staged for it.
    ///
    /// The server is read first, so a commit that lands between the two reads cannot make an
    /// event appear twice. A stream the server does not have is logged as a warning only when
    /// nothing is staged for it either: with staged events it is a stream the unit of work is
    /// creating.
    private func serverAndStagedRecords(of streamName: String, from cursor: RevisionCursor) async throws
        -> (server: [any RecordedEventLike]?, staged: [any RecordedEventLike]) {
        let serverRecords: [any RecordedEventLike]?
        var streamNotFound = false
        do {
            serverRecords = try await client.readStream(name: streamName, from: cursor, resolveLinks: true)
        } catch EventStoreClientError.streamNotFound {
            serverRecords = nil
            streamNotFound = true
        } catch KurrentError.resourceDeleted {
            // Tombstoned by `purge`.
            serverRecords = nil
        } catch {
            logger.error("The error happened when fetching events: \(error)")
            throw error
        }
        let staged = stagedRecords(of: streamName)
        if streamNotFound, staged.isEmpty {
            logger.warning("Skip an error happened, stream not found: \(streamName)")
        }
        return (serverRecords, staged)
    }

    /// The events the current unit of work has staged for `streamName`, as records numbered
    /// with the revisions they are predicted to get; empty outside a unit of work, when the
    /// unit of work has no backend for this coordinator's client, or when nothing is staged
    /// for the stream.
    ///
    /// It only looks: a read never creates the backend, binds the unit of work to this
    /// client or throws because of it. A unit of work that commits through another client
    /// or has ended reads as one with nothing staged, and so does a backend whose commit
    /// started after this read found it, which only a task that outlived the unit of work
    /// can run into. The server was read before, so that read returns the server's events
    /// from before the commit, none of them twice.
    ///
    /// The numbering starts from the staged batch's own expected revision, never from the
    /// last record read from the server: a record the mapper skips, or an empty
    /// `afterRevision` window, would make that one wrong.
    private func stagedRecords(of streamName: String) -> [any RecordedEventLike] {
        guard let backend = UnitOfWork.current?.existingBackend(KurrentUnitOfWorkBackend.self, identity: client.identity),
              let staged = backend.stagedEventsIfUncommitted(stream: streamName)
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
