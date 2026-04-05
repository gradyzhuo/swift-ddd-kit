package enum KurrentDBProjectionError: Error, Equatable, Sendable {
    case missingIdFieldForPlainEvent(modelName: String, eventName: String)
    case emptyCustomHandlerBody(eventName: String)
}
