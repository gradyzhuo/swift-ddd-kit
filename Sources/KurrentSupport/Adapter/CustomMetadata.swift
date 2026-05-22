import EventSourcing

public struct CustomMetadata: EventMetadata {
    public let operatorId: String

    public init(operatorId: String) {
        self.operatorId = operatorId
    }
}
