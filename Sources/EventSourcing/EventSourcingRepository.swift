import DDDCore
import Foundation

public protocol EventSourcingRepository<StorageCoordinator>: Repository {
    associatedtype StorageCoordinator: EventStorageCoordinator<AggregateRootType>

    var coordinator: StorageCoordinator { get }
    
    func find(byId id: AggregateRootType.ID) async throws -> AggregateRootType?
    func save(aggregateRoot: AggregateRootType, external: [String:String]?) async throws
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
        var aggregateRoot = try await AggregateRootType(events: events.filter{ !($0 is AggregateRootType.DeletedEventType) })

        if let deletedEvent {
            try await aggregateRoot?.markDelete()
            try await aggregateRoot?.apply(event: deletedEvent)
        }
        
        await aggregateRoot?.update(version: fetchEventsResult.latestRevision)

        try await aggregateRoot?.clearAllDomainEvents()

        return aggregateRoot
    }

    public func save(aggregateRoot: AggregateRootType, external: [String:String]?) async throws {
        let latestRevision: UInt64? = try await coordinator.append(events: aggregateRoot.events, byId: aggregateRoot.id, version: aggregateRoot.version, external: external)
        if let latestRevision {
            await aggregateRoot.update(version: latestRevision)
        }
        try await aggregateRoot.clearAllDomainEvents()
    }
    
    public func delete(byId id: AggregateRootType.ID, external: [String:String]?) async throws {
        guard let aggregateRoot = try await find(byId: id) else {
            throw DDDError.aggregateNotFound(usecase: "DeleteAggregateRoot", aggregateRootType: AggregateRootType.self, aggregateRootId: "\(id)")
        }
        
        try await aggregateRoot.markDelete()
        try await save(aggregateRoot: aggregateRoot, external: external)
    }
    
    /// 危險操作!! 完全移除，不可恢復
    public func purge(byId id: AggregateRootType.ID) async throws {
        guard let _ = try await find(byId: id) else {
            throw DDDError.aggregateNotFound(usecase: "DeleteAggregateRoot", aggregateRootType: AggregateRootType.self, aggregateRootId: "\(id)")
        }
        try await coordinator.purge(byId: id)
    }
}
