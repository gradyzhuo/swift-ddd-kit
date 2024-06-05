import Foundation

public protocol DeletedEvent: DomainEvent {
    init(eventId: String, aggregateId: String)
}
