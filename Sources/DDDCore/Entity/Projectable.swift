

public enum StreamCategoryRule {
    case fromClass(withPrefix: String)
    case custom(String)
}

public protocol Projectable {
    static var categoryRule: StreamCategoryRule { get }
    static var category: String { get }
    
}

extension Projectable {
    public static func getStreamName(id: String) -> String {
        "\(category)-\(id)"
    }
}
