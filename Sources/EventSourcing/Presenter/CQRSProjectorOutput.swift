import Foundation

public struct CQRSProjectorOutput<ReadModelType: ReadModel> {
    public let readModel: ReadModelType
    public let message: String?
    
    public init(readModel: ReadModelType, message: String?) {
        self.readModel = readModel
        self.message = message
    }
}
