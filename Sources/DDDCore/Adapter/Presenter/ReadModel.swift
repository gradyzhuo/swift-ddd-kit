@available(*, deprecated, message: "Using EvnetSourcingPresenter.ReadModel insteads.")
public protocol ReadModel: Codable, Sendable {
    associatedtype ID: Hashable & Sendable
    associatedtype CreatedEventType: DomainEvent
    
    static var category: String { get }
    
    var id: ID { get }
    init?(events: [any DomainEvent]) async throws
    init?(first createdEvent: CreatedEventType, other events: [any DomainEvent]) throws
    mutating func when(happened event: some DomainEvent) throws
}

extension ReadModel {
    
    public static var category: String {
        "\(Self.self)"
    }

    public static func getStreamName(id: ID) -> String {
        "\(category)-\(id)"
    }

    public init?(events: [any DomainEvent]) throws {
        var events = events
        guard let createdEvent = events.removeFirst() as? CreatedEventType else {
            return nil
        }

        try self.init(first: createdEvent, other: events)
    }

    public mutating func restore(event: some DomainEvent) throws {
        try when(happened: event)
    }

    public mutating func restore(events: [any DomainEvent]) throws {
        for event in events {
            try restore(event: event)
        }
    }
}
