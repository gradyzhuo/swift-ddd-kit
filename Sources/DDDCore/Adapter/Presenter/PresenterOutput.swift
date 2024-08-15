import Foundation

public protocol PresenterOutput: Sendable, Codable {
    associatedtype ReadModelType: ReadModel

    var readModel: ReadModelType { get }
    var message: String? { get }
}