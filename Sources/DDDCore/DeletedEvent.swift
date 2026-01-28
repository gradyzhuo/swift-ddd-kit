import Foundation

public protocol DeletedEvent: DomainEvent {
    init(id: UUID, aggregateRootId: String, occurred: Date)
}

extension DeletedEvent {
    public init(aggregateRootId: String){
        self.init(id: .init(), aggregateRootId: aggregateRootId, occurred: .now)
    }
}
