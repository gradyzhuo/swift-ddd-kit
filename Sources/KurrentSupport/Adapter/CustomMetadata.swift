public struct CustomMetadata: Codable {
    public let className: String
    public let userId: String?

    public init(className: String, userId: String?) {
        self.className = className
        self.userId = userId
    }
}

