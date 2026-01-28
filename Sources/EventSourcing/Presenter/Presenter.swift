import Foundation
import DDDCore



public protocol EventSourcingPresenter: Actor where ID == String {
    associatedtype ID: Hashable
    associatedtype ReadModel: Codable, Sendable

    var readModel: ReadModel? { get }
    
    init(id: ID)
    func when(happened event: some DomainEvent) throws
}

extension EventSourcingPresenter {
    
    public static func buildReadModel(id: ID, events: [any DDDCore.DomainEvent]) async throws -> ReadModel? {
        guard events.count > 0 else {
            throw DDDError.eventsNotFoundInPresenter(operation: "buildReadModel", presenterType: "\(Self.self)")
        }
        let presenter = Self(id: id)
        for event in events {
            try await presenter.when(happened: event)
        }
        return await presenter.readModel
    }
}
