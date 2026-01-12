import Foundation

public protocol AggregateRoot: Projectable, Entity {
    associatedtype CreatedEventType: DomainEvent
    associatedtype DeletedEventType: DeletedEvent

    var metadata: AggregateRootMetadata { get }

    init?(first createdEvent: CreatedEventType, other events: [any DomainEvent]) throws

    func add(domainEvent: some DomainEvent) throws
    func ensureInvariant() throws
    func markDelete() throws
}

extension AggregateRoot {
    public init?(events: [any DomainEvent]) throws {
        var events = events
        guard let createdEvent = events.removeFirst() as? CreatedEventType else {
            return nil
        }

        try self.init(first: createdEvent, other: events)
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

    public var version: UInt64? {
        metadata.version
    }

    public func markDelete() throws {
        fatalError("Not Implemented.")
    }
    
    public func apply(event: some DomainEvent) throws {
        guard !deleted else {
            throw DDDError.operationNotAllow(operation: "apply", reason: "the aggregate root `\(Self.self)(\(id))` is deleted.", userInfos: ["event": event, "aggregateRootType": "\(Self.self)", "aggregateRootId": id])
        }
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
