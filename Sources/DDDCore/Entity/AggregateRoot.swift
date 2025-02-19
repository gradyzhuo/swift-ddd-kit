import Foundation

public protocol AggregateRoot: Projectable, Entity {
    associatedtype CreatedEventType: DomainEvent
    associatedtype DeletedEventType: DeletedEvent

    var metadata: AggregateRootMetadata { get }

    init?(first createdEvent: CreatedEventType, other events: [any DomainEvent]) throws

    func add(domainEvent: some DomainEvent) throws
}

extension AggregateRoot {
    public init?(events: [any DomainEvent]) throws {
        var sortedEvents = events.sorted {
            $0.occurred < $1.occurred
        }
        guard let createdEvent = sortedEvents.removeFirst() as? CreatedEventType else {
            return nil
        }

        try self.init(first: createdEvent, other: sortedEvents)
    }
    
    public var deleted: Bool {
        set{
            metadata.deleted = newValue
        }
        get {
            metadata.deleted
        }
    }

    public var events: [any DomainEvent] {
        metadata.events
    }

    public var version: UInt? {
        metadata.version
    }

    public func apply(event: some DomainEvent) throws {
        try ensureInvariant()
        try when(happened: event)
        try ensureInvariant()
        try add(domainEvent: event)
    }

    public func apply(events: [any DomainEvent]) throws {
        for event in events {
            try apply(event: event)
        }
    }

    public func add(domainEvent: some DomainEvent) throws {
        metadata.events.append(domainEvent)
    }

    public func clearAllDomainEvents() throws {
        metadata.events.removeAll()
    }

    public func ensureInvariant() throws {}
}
