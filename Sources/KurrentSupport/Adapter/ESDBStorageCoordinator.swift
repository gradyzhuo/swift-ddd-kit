import DDDCore
import EventSourcing
import EventStoreDB
import Foundation
import Logging

public class KurrentStorageCoordinator<ProjectableType: Projectable>: EventStorageCoordinator {
    let logger = Logger(label: "KurrentStorageCoordinator")
    let eventMapper: any EventTypeMapper
    let client: KurrentDBClient

    public init(client: KurrentDBClient, eventMapper: any EventTypeMapper) {
        self.eventMapper = eventMapper
        self.client = client
    }
    
    public init(client: EventStoreDBClient, eventMapper: any EventTypeMapper) {
        self.eventMapper = eventMapper
        self.client = client.underlyingClient
    }

    public func append(events: [any DDDCore.DomainEvent], byId id: ProjectableType.ID, version: UInt64?, external: [String:String]?) async throws -> UInt64? {
        let streamName = ProjectableType.getStreamName(id: id)
        let events = try events.map {
            let customMetadata = CustomMetadata(
                className: "\(type(of: $0))",
                external: external
            )
            let encoder = JSONEncoder()
            return try EventData(id: $0.id, eventType: $0.eventType, model: $0, customMetadata: encoder.encode(customMetadata))
        }
        let response = try await client.appendStream(.init(name: streamName), events: events){ options in
            guard let version else {
                return options.revision(expected: .any)
            }
            return options.revision(expected: .revision(UInt64(version)))
        }

        return response.currentRevision.flatMap {
            .init($0)
        }
    }

    public func fetchEvents(byId id: ProjectableType.ID) async throws -> (events: [any DomainEvent], latestRevision: UInt64)? {
        
        let streamName = ProjectableType.getStreamName(id: id)
        do{
            let responses = try await client.readStream(.init(name: streamName)){
                    $0.startFrom(revision: .start)
                      .resolveLinks()
            }

            let eventWrappers: [(event: any DomainEvent, revision: UInt64)] = try await responses.reduce(into: .init()) {
                do{
                    let recordedEvent = try $1.event.record
                    guard let event = try self.eventMapper.mapping(eventData: recordedEvent) else {
                        return
                    }
                    $0.append((event: event, revision: recordedEvent.revision))
                }catch {
                    logger.warning("skipped event cause error happened. error: \(error)")
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
        } catch KurrentError.resourceNotFound(let reason){
            logger.warning("Skip an error happened in esdb, with reason: \(reason)")
            return nil
        }catch{
            logger.error("The error happened when fetching events: \(error)")
            throw error
        }
    }
    
    public func purge(byId id: ProjectableType.ID) async throws {
        try await self.client.deleteStream(ProjectableType.getStreamName(id: id))
    }
    
}
