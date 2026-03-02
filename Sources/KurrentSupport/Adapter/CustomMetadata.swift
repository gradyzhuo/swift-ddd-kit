public struct CustomMetadata: Codable, Sendable {
    public let className: String
    public var external: [String: String]?

    public init(className: String, external: [String: String]?) {
        self.className = className
        self.external = external ?? [:]
    }
}

extension CustomMetadata {
    public var operatorId: String?{
        set {
            var external = external ?? [:]
            external["operatorId"] = newValue
            self.external = external
        }
        get {
            guard let external else { return nil }
            return external["operatorId"] ?? external["userId"]
        }
    }
}

