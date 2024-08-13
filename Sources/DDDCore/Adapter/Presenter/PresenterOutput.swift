import Foundation

public protocol PresenterOutput: Sendable {
    var readModel: (any ReadModel)? { get }
    var message: String? { get }
}