import DDDCore
import EventSourcing
import EventStoreDB
import Foundation

public class KurrentStorageCoordinator<AggregateRootType: AggregateRoot>: EventStorageCoordinator {
    let eventMapper: any EventTypeMapper
    let client: EventStoreDBClient

    public init(client: EventStoreDBClient, eventMapper: any EventTypeMapper) {
        self.eventMapper = eventMapper
        self.client = client
    }

    public func append(events: [any DDDCore.DomainEvent], byId aggregateRootId: AggregateRootType.ID, version: UInt?) async throws -> UInt? {
        let streamName = AggregateRootType.getStreamName(id: aggregateRootId)
        let events = try events.map {
            try EventData(id: $0.id, eventType: $0.eventType, payload: $0)
        }

        let response = try await client.appendStream(to: .init(name: streamName), events: events) { options in
            guard let version else {
                return options.revision(expected: .any)
            }
            return options.revision(expected: .revision(UInt64(version)))
        }

        return response.current.revision.flatMap {
            .init($0)
        }
    }

    public func fetchEvents(byId aggregateRootId: AggregateRootType.ID) async throws -> [any DomainEvent]? {
        let streamName = AggregateRootType.getStreamName(id: aggregateRootId)
        let responses = try client.readStream(to: .init(name: streamName), cursor: .start)

        return try await responses.reduce(into: nil) {
            guard case let .event(readEvent) = $1.content else {
                return
            }

            guard let event = try self.eventMapper.mapping(eventData: readEvent.recordedEvent) else {
                return
            }

            if $0 == nil {
                $0 = .init()
            }
            $0?.append(event)
        }
    }
}
