import DDDCore

public protocol EventStorageProjector<StorageCoordinator>: Actor, Sendable {
    associatedtype PresenterType: EventSourcingPresenter
    associatedtype StorageCoordinator: EventStorageCoordinator<PresenterType>

    var coordinator: StorageCoordinator { get }
}

extension EventStorageProjector {

    public func find(byId id: PresenterType.ID) async throws -> PresenterType.ReadModel? {
        guard let fetechedEvents = try await coordinator.fetchEvents(byId: id) else {
            return nil
        }
        
        return try await PresenterType.buildReadModel(id: id, events: fetechedEvents.events)
    }
}
