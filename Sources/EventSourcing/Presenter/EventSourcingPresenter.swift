import Foundation
import DDDCore

public protocol EventSourcingPresenter: Projectable {
    associatedtype ReadModelType: ReadModel
    
    func apply(events: [any DomainEvent]) throws
    func buildReadModel() throws -> PresenterOutput<ReadModelType>?
}

extension EventSourcingPresenter {
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
}
