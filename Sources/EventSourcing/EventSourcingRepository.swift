import DDDCore
import Foundation

public protocol EventSourcingRepository<AggregateRootType, StorageCoordinator>: AnyObject {
    associatedtype AggregateRootType: AggregateRoot
    associatedtype StorageCoordinator: EventStorageCoordinator where StorageCoordinator.AggregateRootType == AggregateRootType

    var coordinator: StorageCoordinator { get }
}

extension EventSourcingRepository {
    public func find(byId id: AggregateRootType.ID, forcly: Bool = false) async throws -> AggregateRootType? {
        guard var events = try await coordinator.fetchEvents(byId: id) else {
            return nil
        }

        guard !forcly && (events.contains{ $0 is AggregateRootType.DeletedEventType }) else {
            return nil
        }

        let deletedEvent = events.first{
            $0 is AggregateRootType.DeletedEventType
        } as? AggregateRootType.DeletedEventType

        events.removeAll{
            $0 is AggregateRootType.DeletedEventType
        }

        let aggregateRoot = try AggregateRootType.init(events: events)

        if let deletedEvent {
            try aggregateRoot?.apply(event: deletedEvent)
        }

        try aggregateRoot?.clearAllDomainEvents()

        return aggregateRoot
    }

    public func save(aggregateRoot: AggregateRootType) async throws {
        let latestRevision: UInt? = try await coordinator.append(events: aggregateRoot.events, byId: aggregateRoot.id, version: aggregateRoot.version)
        aggregateRoot.metadata.version = latestRevision
        try aggregateRoot.clearAllDomainEvents()
    }

    public func delete(byId id: AggregateRootType.ID) async throws {
        // coordinators[id]?.events.removeAll()
        guard let aggregateRoot = try await find(byId: id) else {
            return
        }
        try aggregateRoot.markAsDelete()
        try await save(aggregateRoot: aggregateRoot)
    }
}
