import Foundation
import DDDCore
import Logging

public protocol EventSourcingProjector: EventStreamNaming {
    associatedtype Input: CQRSProjectorInput
    associatedtype ReadModelType: ReadModel
    associatedtype Store: EventStore

    var store: Store { get }
    
    func apply(readModel: inout ReadModelType, events: [any DomainEvent]) throws
    func buildReadModel(input: Input) throws -> ReadModelType?
}

extension EventSourcingProjector {
    
    private var logger: Logger {
        get{
            return .init(label: "<\(Self.self)>")
        }
    }
    
    public static var categoryRule: StreamCategoryRule{
        return .fromClass(withPrefix: "")
    }
    
    public static var category: String{
        get{
            return switch categoryRule {
            case .fromClass(let prefix):
                "\(prefix)\(Self.self)".replacing("Presenter", with: "").replacing("Projector", with: "")
            case .custom(let customCategory):
                customCategory
            }
        }
    }
    
    /// Fetches the events of `input.id` and folds them into a read model.
    ///
    /// Returns `nil` when the stream does not exist, when `buildReadModel` returns `nil`, and
    /// when `buildReadModel` or `apply` throws. The last case is logged as a warning with the
    /// error; errors from the store are thrown.
    public func execute(input: Input) async throws -> CQRSProjectorOutput<ReadModelType>?{
        guard let fetechedResult = try await store.fetchEvents(byId: input.id) else {
            return nil
        }
        
        guard fetechedResult.events.count > 0 else {
            throw DDDError.eventsNotFoundInProjector(operation: "buildReadModel", projectorType: "\(Self.self)")
        }
        
        do{
            guard var readModel = try buildReadModel(input: input) else {
                return nil
            }
            try apply(readModel: &readModel,events: fetechedResult.events)
            return .init(readModel: readModel, message: nil)
        } catch {
            logger.warning("Returned no read model: buildReadModel or apply threw.", metadata: [
                "id": "\(input.id)",
                "error": "\(error)",
            ])
            return nil
        }
    }
}
