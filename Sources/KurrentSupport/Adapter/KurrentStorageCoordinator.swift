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

    public func append(
        events: [any DDDCore.DomainEvent],
        byId id: String,
        version: UInt64?,
        metadata: Metadata?
    ) async throws -> UInt64? {
        let streamName = StreamNaming.getStreamName(id: id)
        let encoder = JSONEncoder()
        let metadataBytes: Data? = try metadata.map { try encoder.encode($0) }
        let eventDataList = try events.map { event in
            try EventData(
                id: event.id,
                eventType: event.eventType,
                model: event,
                customMetadata: metadataBytes
            )
        }
        // A `nil` version means the aggregate has never been persisted —
        // expect `.noStream` so a concurrent/duplicate create collides
        // with the existing stream instead of silently succeeding under
        // `.any` (which skips the concurrency check altogether).
        let expectedRevision: StreamRevision = version.map { .at($0) } ?? .noStream
        return try await client.append(events: eventDataList, toStream: streamName, category: StreamNaming.category, expectedRevision: expectedRevision)
    }

    public func fetchEvents(byId id: String) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)? {
        let streamName = StreamNaming.getStreamName(id: id)
        do {
            let records = try await client.readStream(name: streamName, from: .start, resolveLinks: true)

            let eventWrappers: [EventWrapped] = records.reduce(into: .init()) {
                do {
                    guard let event = try self.eventMapper.mapping(eventData: $1) else {
                        return
                    }
                    $0.append(.init(event: event, revision: $1.revision))
                } catch {
                    logger.warning("skipped event cause error happened. error: \(error)")
                    return
                }
            }

            guard let latestRevision = eventWrappers.last?.revision else {
                return nil
            }

            let events = eventWrappers.map(\.event)
            let sortedEvents = events.sorted {
                $0.occurred < $1.occurred
            }

            return (events: sortedEvents, latestRevision: latestRevision)
        } catch EventStoreClientError.streamNotFound {
            logger.warning("Skip an error happened, stream not found: \(streamName)")
            return nil
        } catch {
            logger.error("The error happened when fetching events: \(error)")
            throw error
        }
    }

    public func fetchEvents(byId id: String, afterRevision revision: UInt64) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)? {
        let streamName = StreamNaming.getStreamName(id: id)
        do {
            let records = try await client.readStream(name: streamName, from: .specified(revision + 1), resolveLinks: true)

            let eventWrappers: [EventWrapped] = records.reduce(into: .init()) {
                do {
                    guard let event = try self.eventMapper.mapping(eventData: $1) else {
                        return
                    }
                    $0.append(.init(event: event, revision: $1.revision))
                } catch {
                    logger.warning("skipped event cause error happened. error: \(error)")
                    return
                }
            }

            guard let latestRevision = eventWrappers.last?.revision else {
                return (events: [], latestRevision: revision)
            }

            let sortedEvents = eventWrappers.map(\.event).sorted {
                $0.occurred < $1.occurred
            }

            return (events: sortedEvents, latestRevision: latestRevision)
        } catch EventStoreClientError.streamNotFound {
            logger.warning("Skip an error happened, stream not found: \(streamName)")
            return nil
        } catch {
            logger.error("The error happened when fetching events: \(error)")
            throw error
        }
    }

    public func purge(byId id: String) async throws {
        let streamName = StreamNaming.getStreamName(id: id)
        try await self.client.deleteStream(name: streamName, expectedRevision: .streamExists)
    }
}
