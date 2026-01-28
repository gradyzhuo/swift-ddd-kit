public protocol Projectable: Actor {

    associatedtype ID: Hashable & Sendable
    
    static var category: String { get }
    
    var id: ID { get }
    init?(events: [any DomainEvent]) async throws
    func when(happened event: some DomainEvent) throws
}

extension Projectable {
    public static var category: String {
        "\(Self.self)"
    }

    public static func getStreamName(id: ID) -> String {
        "\(category)-\(id)"
    }
}
