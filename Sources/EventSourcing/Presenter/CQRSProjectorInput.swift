import Foundation

public protocol CQRSProjectorInput: Sendable {
    var id: String { get }
}
