

public enum StreamCategoryRule {
    case fromClass(withPrefix: String)
    case custom(String)
}

public protocol Projectable {

    associatedtype ID: Hashable
    
    static var categoryRule: StreamCategoryRule { get }
    static var category: String { get }
    
    var id: ID { get }
}

extension Projectable {
    public static func getStreamName(id: ID) -> String {
        "\(category)-\(id)"
    }
}
