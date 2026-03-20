import DDDCore
import Foundation

public protocol EventStorageCoordinator {
    func fetchEvents(byId id: String) async throws -> (events: [any DomainEvent], latestRevision: UInt64)?
    func append(events: [any DomainEvent], byId id: String, version: UInt64?, external: [String:String]?) async throws -> UInt64?
    func purge(byId id: String) async throws
}
