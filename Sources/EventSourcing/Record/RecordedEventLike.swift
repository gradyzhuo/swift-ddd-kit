import Foundation

/// A single stored/delivered event, decoupled from any concrete store's record type.
public protocol RecordedEventLike: Sendable {
    var id: UUID { get }
    var eventType: String { get }
    var revision: UInt64 { get }
    var customMetadata: Data { get }
    /// Name of the stream this event was originally appended to — e.g. `"Order-42"`,
    /// even when delivered via a resolved `$ce-Order` category-projection link.
    var streamName: String { get }
    func decode<T: Decodable>(to type: T.Type) throws -> T?
}
