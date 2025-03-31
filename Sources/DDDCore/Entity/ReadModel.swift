public protocol ReadModel: Projectable, Codable {
    associatedtype CreatedEventType: DomainEvent

    init?(first createdEvent: CreatedEventType, other events: [any DomainEvent]) throws
}

extension ReadModel {

    public init?(events: [any DomainEvent]) throws {
        var sortedEvents = events.sorted {
            $0.occurred < $1.occurred
        }
        guard let createdEvent = sortedEvents.removeFirst() as? CreatedEventType else {
            return nil
        }

        try self.init(first: createdEvent, other: sortedEvents)
    }

    public func restore(event: some DomainEvent) throws {
        try when(happened: event)
    }

    public func restore(events: [any DomainEvent]) throws {
        for event in events {
            try restore(event: event)
        }
    }
}
