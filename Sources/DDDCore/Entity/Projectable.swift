public protocol Projectable {

    init?(events: [any DomainEvent]) throws
    func when(happened event: some DomainEvent) throws
    func ensureInvariant() throws
}