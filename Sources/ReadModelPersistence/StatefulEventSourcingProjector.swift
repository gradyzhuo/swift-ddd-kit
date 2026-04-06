import DDDCore
import EventSourcing

public protocol StatefulEventSourcingProjector: EventSourcingProjector where ReadModelType: Sendable {
    associatedtype Store: ReadModelStore where Store.Model == ReadModelType

    var store: Store { get }

    /// Map the projector input to the read model's store key.
    /// A default is provided when `ReadModelType.ID == String`.
    func readModelId(for input: Input) -> ReadModelType.ID
}

// MARK: - Default readModelId when ID is String

extension StatefulEventSourcingProjector where ReadModelType.ID == String {
    public func readModelId(for input: Input) -> String {
        input.id
    }
}

// MARK: - Default execute with incremental update

extension StatefulEventSourcingProjector {

    public func execute(input: Input) async throws -> CQRSProjectorOutput<ReadModelType>? {
        let modelId = readModelId(for: input)
        let stored = try await store.fetch(byId: modelId)

        if let stored {
            // Incremental path: fetch only events after the stored revision.
            guard let result = try await coordinator.fetchEvents(byId: input.id, afterRevision: stored.revision) else {
                return .init(readModel: stored.readModel, message: nil)
            }

            if result.events.isEmpty {
                return .init(readModel: stored.readModel, message: nil)
            }

            var readModel = stored.readModel
            try apply(readModel: &readModel, events: result.events)
            try await store.save(readModel: readModel, revision: result.latestRevision)

            return .init(readModel: readModel, message: nil)
        } else {
            // Full replay path: first-time projection.
            guard let fetchedResult = try await coordinator.fetchEvents(byId: input.id) else {
                return nil
            }

            guard !fetchedResult.events.isEmpty else {
                throw DDDError.eventsNotFoundInPresenter(
                    operation: "buildReadModel",
                    presenterType: "\(Self.self)"
                )
            }

            guard var readModel = try buildReadModel(input: input) else {
                return nil
            }

            try apply(readModel: &readModel, events: fetchedResult.events)
            try await store.save(readModel: readModel, revision: fetchedResult.latestRevision)

            return .init(readModel: readModel, message: nil)
        }
    }
}
