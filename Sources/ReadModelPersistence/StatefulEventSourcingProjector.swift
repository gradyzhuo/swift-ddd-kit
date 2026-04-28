import DDDCore
import EventSourcing

/// A wrapper that adds stateful read model persistence to any `EventSourcingProjector`.
///
/// Instead of re-implementing projection logic, pass an existing projector and a store.
/// `execute(input:)` handles incremental/full-replay automatically:
/// - **No snapshot**: full replay → build + apply all events → save to store
/// - **Snapshot found**: incremental → apply only events after stored revision → update store
///
/// ```swift
/// let projector = OrderProjector(coordinator: coordinator)
/// let stateful  = StatefulEventSourcingProjector(projector: projector, store: store)
/// let result    = try await stateful.execute(input: input)
/// ```
public struct StatefulEventSourcingProjector<
    Projector: EventSourcingProjector,
    Store: ReadModelStore
>: Sendable where Store.Model == Projector.ReadModelType, Projector: Sendable {

    public let projector: Projector
    public let store: Store
    private let _readModelId: @Sendable (Projector.Input) -> Store.Model.ID

    /// Designated initialiser — supply a custom `readModelId` closure when
    /// `ReadModelType.ID` is not `String`.
    public init(
        projector: Projector,
        store: Store,
        readModelId: @Sendable @escaping (Projector.Input) -> Store.Model.ID
    ) {
        self.projector = projector
        self.store = store
        self._readModelId = readModelId
    }

    public func execute(input: Projector.Input) async throws -> CQRSProjectorOutput<Projector.ReadModelType>? {
        let modelId = _readModelId(input)
        let stored  = try await store.fetch(byId: modelId)

        if let stored {
            // Incremental path — fetch only events after the stored revision.
            guard let result = try await projector.coordinator.fetchEvents(
                byId: input.id, afterRevision: stored.revision
            ) else {
                return .init(readModel: stored.readModel, message: nil)
            }

            if result.events.isEmpty {
                return .init(readModel: stored.readModel, message: nil)
            }

            var readModel = stored.readModel
            try projector.apply(readModel: &readModel, events: result.events)
            try await store.save(readModel: readModel, revision: result.latestRevision)
            return .init(readModel: readModel, message: nil)

        } else {
            // Full replay path — first-time projection.
            guard let fetchedResult = try await projector.coordinator.fetchEvents(byId: input.id) else {
                return nil
            }

            guard !fetchedResult.events.isEmpty else {
                throw DDDError.eventsNotFoundInProjector(
                    operation: "buildReadModel",
                    projectorType: "\(Projector.self)"
                )
            }

            guard var readModel = try projector.buildReadModel(input: input) else {
                return nil
            }

            try projector.apply(readModel: &readModel, events: fetchedResult.events)
            try await store.save(readModel: readModel, revision: fetchedResult.latestRevision)
            return .init(readModel: readModel, message: nil)
        }
    }
}

// MARK: - Convenience init when ReadModel.ID == String

extension StatefulEventSourcingProjector where Store.Model.ID == String {
    /// Convenience initialiser when `ReadModelType.ID == String` —
    /// `readModelId` defaults to `input.id`.
    public init(projector: Projector, store: Store) {
        self.init(projector: projector, store: store, readModelId: { $0.id })
    }
}
