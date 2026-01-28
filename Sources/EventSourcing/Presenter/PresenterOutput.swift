import Foundation

public struct PresenterOutput<ReadModelType> {
    public let readModel: ReadModelType
    public let message: String?
    
    internal init(readModel: ReadModelType, message: String?) {
        self.readModel = readModel
        self.message = message
    }
}
