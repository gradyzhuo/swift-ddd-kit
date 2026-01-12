import DDDCore
import Foundation

public protocol EventStorageCoordinator<ProjectableType>: AnyObject {
    associatedtype ProjectableType: Projectable

    func fetchEvents(byId id: ProjectableType.ID) async throws -> (events: [any DomainEvent], latestRevision: UInt64)?
    func append(events: [any DomainEvent], byId id: ProjectableType.ID, version: UInt64?, external: [String:String]?) async throws -> UInt64?
    func purge(byId id: ProjectableType.ID) async throws
}
