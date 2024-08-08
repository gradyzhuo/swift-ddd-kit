public protocol ReadModel: Projectable {

    init?(events: [any DomainEvent]) throws
}

extension ReadModel {

    public func restore(event: some DomainEvent) throws {
        try ensureInvariant()
        try when(happened: event)
        try ensureInvariant()
    }

    public func restore(events: [any DomainEvent]) throws {
        let sortedEvents = events.sorted {
            $0.occurred < $1.occurred
        }
        for event in sortedEvents {
            try restore(event: event)
        }
    }

    public func ensureInvariant() throws {}
}