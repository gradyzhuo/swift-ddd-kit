import Foundation
import DDDCore
import Logging

public protocol EventSourcingProjector: EventStreamNaming {
    associatedtype Input: CQRSProjectorInput
    associatedtype ReadModelType: ReadModel
    associatedtype StorageCoordinator: EventStorageCoordinator
    
    var coordinator: StorageCoordinator { get }
    
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
                "\(prefix)\(Self.self)".replacing("Presenter", with: "")
            case .custom(let customCategory):
                customCategory
            }
        }
    }
    
    public func execute(input: Input) async throws -> CQRSProjectorOutput<ReadModelType>?{
        guard let fetechedResult = try await coordinator.fetchEvents(byId: input.id) else {
            return nil
        }
        
        guard fetechedResult.events.count > 0 else {
            throw DDDError.eventsNotFoundInPresenter(operation: "buildReadModel", presenterType: "\(Self.self)")
        }
        
        do{
            guard var readModel = try buildReadModel(input: input) else {
                return nil
            }
            try apply(readModel: &readModel,events: fetechedResult.events)
            return .init(readModel: readModel, message: nil)
        } catch {
            return nil
        }
    }
}
