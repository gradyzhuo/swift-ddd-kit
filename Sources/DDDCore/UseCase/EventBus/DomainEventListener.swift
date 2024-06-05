import Foundation

public protocol DomainEventListener {
    associatedtype EventType: DomainEvent

    func observed(event: EventType) async throws
}
