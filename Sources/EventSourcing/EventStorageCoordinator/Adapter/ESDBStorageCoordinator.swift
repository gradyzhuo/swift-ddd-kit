import Foundation
import DDDCore
import EventStoreDB

public protocol EventTypeMapper {
    func mapping(eventType: String, payload: Data) -> (any DomainEvent)?
   
    init()
}

public class KurrentStorageCoordinator<AggregateRootType: AggregateRoot, Mapper: EventTypeMapper>: EventStorageCoordinator {
    let mapper: Mapper
    let client: EventStoreDBClient
    
    public init(mapper: Mapper, client: EventStoreDBClient){
        self.mapper = mapper
        self.client = client
    }
    
    public func append(events: [any DDDCore.DomainEvent], byId aggregateRootId: AggregateRootType.ID, version: UInt?) async throws -> UInt? {
        let streamName = AggregateRootType.getStreamName(id: aggregateRootId)
        let events = try events.map{
            try EventData.init(eventType: $0.eventType, payload: $0)
        }
        
        let response = try await client.appendStream(to: .init(name: streamName), events: events) { options in
            guard let version else {
                return options
            }
            return options.revision(expected: .revision(UInt64(version)))
        }
        
        return response.current.revision.flatMap{
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
            
            guard let event = self.mapper.mapping(eventType: readEvent.recordedEvent.eventType, payload: readEvent.recordedEvent.data) else {
                return
            }
            
            if $0 == nil {
                $0 = .init()
            }
            $0?.append(event)
        }
    }
}
