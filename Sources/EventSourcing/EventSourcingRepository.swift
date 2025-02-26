import DDDCore
import Foundation

public protocol EventSourcingRepository<StorageCoordinator>: Repository {
    associatedtype StorageCoordinator: EventStorageCoordinator<AggregateRootType>

    var coordinator: StorageCoordinator { get }
    
    func find(byId id: AggregateRootType.ID) async throws -> AggregateRootType?
    func save(aggregateRoot: AggregateRootType, customMetadata: Data?) async throws
}

extension EventSourcingRepository {
    public func find(byId id: AggregateRootType.ID) async throws -> AggregateRootType? {
        return try await self.find(byId: id, hiddingDeleted: true)
    }
    
    public func find(byId id: AggregateRootType.ID, hiddingDeleted: Bool) async throws -> AggregateRootType? {
        
        guard let fetchEventsResult = try await coordinator.fetchEvents(byId: id) else {
            return nil
        }
        
        let events = fetchEventsResult.events

        guard !(hiddingDeleted && (events.contains { $0 is AggregateRootType.DeletedEventType })) else {
            return nil
        }

        let deletedEvent = events.first {
            $0 is AggregateRootType.DeletedEventType
        } as? AggregateRootType.DeletedEventType

        //濾掉 AggregateRootType 是 AggregateRootType.DeletedEventType 的 Event
        let aggregateRoot = try AggregateRootType(events: events.filter{ !($0 is AggregateRootType.DeletedEventType) })

        if let deletedEvent {
            try aggregateRoot?.apply(event: deletedEvent)
        }
        
        aggregateRoot?.metadata.version = fetchEventsResult.latestRevision

        try aggregateRoot?.clearAllDomainEvents()

        return aggregateRoot
    }

    public func save(aggregateRoot: AggregateRootType, customMetadata: Data?) async throws {
        let latestRevision: UInt64? = try await coordinator.append(events: aggregateRoot.events, byId: aggregateRoot.id, version: aggregateRoot.version, customMetadata: customMetadata)
        aggregateRoot.metadata.version = latestRevision
        try aggregateRoot.clearAllDomainEvents()
    }
}
