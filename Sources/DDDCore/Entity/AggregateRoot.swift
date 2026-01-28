import Foundation

public protocol AggregateRoot: Projectable, Entity{
    associatedtype CreatedEventType: DomainEvent
    associatedtype DeletedEventType: DeletedEvent

    var metadata: AggregateRootMetadata { set get }

    init?(first createdEvent: CreatedEventType, other events: [any DomainEvent]) async throws

    func add(domainEvent: some DomainEvent) throws
    func ensureInvariant() throws
    func markDelete() throws
}

extension AggregateRoot {
    public init?(events: [any DomainEvent]) async throws {
        var events = events
        guard let createdEvent = events.removeFirst() as? CreatedEventType else {
            return nil
        }

        try await self.init(first: createdEvent, other: events)
    }
    
    public var deleted: Bool {
        get {
            metadata.deleted
        }
    }

    public var events: [any DomainEvent] {
        get {
            metadata.events
        }
    }

    public var version: UInt64? {
        get {
            metadata.version
        }
    }

    public func markDelete() throws {
        fatalError("Not Implemented.")
    }
    
    public func apply(event: some DomainEvent) throws {
        let deleted = metadata.deleted
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
    
    public func update(version: UInt64){
        metadata.version = version
    }

    public func clearAllDomainEvents() throws {
        metadata.events.removeAll()
    }

    public func ensureInvariant() throws {}
}
