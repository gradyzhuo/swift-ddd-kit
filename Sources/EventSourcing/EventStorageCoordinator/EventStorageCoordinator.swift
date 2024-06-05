import Foundation
import DDDCore

public protocol EventStorageCoordinator<AggregateRootType>: AnyObject {
    associatedtype AggregateRootType: AggregateRoot

    func fetchEvents(byId aggregateRootId: AggregateRootType.ID) async throws -> [any DomainEvent]?
    func append(events: [any DomainEvent], byId aggregateRootId: AggregateRootType.ID, version: UInt?) async throws -> UInt?
    
}
