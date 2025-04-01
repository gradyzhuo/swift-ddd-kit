public protocol ReadModel: Projectable, Codable {
    associatedtype CreatedEventType: DomainEvent

    init?(first createdEvent: CreatedEventType, other events: [any DomainEvent]) throws
}

extension ReadModel {

    public init?(events: [any DomainEvent]) throws {
        var events = events
        guard let createdEvent = events.removeFirst() as? CreatedEventType else {
            return nil
        }

        try self.init(first: createdEvent, other: events)
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
