import Foundation

/// Kit-agnostic view of one recorded domain event — what a translate closure
/// sees. `data` is the raw JSON payload as stored in KurrentDB.
public struct ForwardedRecord: Sendable {
    public let eventType: String
    public let streamName: String
    public let eventId: String
    public let data: Data
    public let occurredAt: Date

    public init(eventType: String, streamName: String, eventId: String, data: Data, occurredAt: Date) {
        self.eventType = eventType
        self.streamName = streamName
        self.eventId = eventId
        self.data = data
        self.occurredAt = occurredAt
    }

    public func decodeBody<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
