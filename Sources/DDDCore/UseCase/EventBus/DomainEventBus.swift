import Foundation

public protocol DomainEventBus {
    associatedtype Subscriber
    var eventSubscribers: [Subscriber] { get }
    
    func publish<EventType: DomainEvent>(event: EventType) async throws
    func subscribe<EventType: DomainEvent>(to eventType: EventType.Type, handler: @escaping (_ event: EventType) async throws -> Void) rethrows
}

extension DomainEventBus {
    public func postAllEvent(fromAggregateRoot aggregateRoot: some AggregateRoot) async throws {
        for event in aggregateRoot.events {
            try await publish(event: event)
        }
    }
}
