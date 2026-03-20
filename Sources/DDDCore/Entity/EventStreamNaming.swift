

public enum StreamCategoryRule {
    case fromClass(withPrefix: String)
    case custom(String)
}

public protocol EventStreamNaming {
    static var categoryRule: StreamCategoryRule { get }
    static var category: String { get }
    
}

extension EventStreamNaming {
    public static func getStreamName(id: String) -> String {
        "\(category)-\(id)"
    }
}
