import DDDCore

package struct GeneralSubscriber<Event: DomainEvent>: EventSubscriber{
    package let eventName: String
    package let handle: @Sendable (Event) async throws -> Void
}

public class EventBus: DomainEventBus {
    public private(set) var eventSubscribers: [any EventSubscriber]

    public func publish(event: some DomainEvent) async throws {
        for eventSubscriber in eventSubscribers {
            if eventSubscriber.eventName == event.eventType {
                try await self.publish(of: eventSubscriber, event: event)
            }
        }
    }
    
    package func publish<Subscriber: EventSubscriber>(of subscriber: Subscriber, event: some DomainEvent) async throws {
        guard let event = event as? Subscriber.Event else {
            return
        }
        try await subscriber.handle(event)
    }

    public func subscribe<EventType: DomainEvent>(to eventType: EventType.Type, handler: @escaping (_ event: EventType) async throws -> Void) rethrows {
        let eventTypeString = "\(eventType)"
        
        let subscriber = GeneralSubscriber<EventType>(eventName: eventTypeString){ event async throws in
            try await handler(event)
        }
        eventSubscribers.append(subscriber)
    }

    public init() {
        eventSubscribers = []
    }
}
