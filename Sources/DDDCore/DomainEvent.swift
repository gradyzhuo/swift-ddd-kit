import Foundation

public protocol DomainEvent: Codable, Identifiable{
    typealias ID = UUID
    
    var eventType: String { get }
    var aggregateRootId: String { get }
    var occurred: Date { get }
}

extension DomainEvent {
    
    var eventType: String {
        get{
            "\(Self.self)"
        }
    }

}
