import Foundation

/// Kit-agnostic view of one recorded domain event — what a translate closure
/// sees. `data` is the raw JSON payload as stored in KurrentDB.
///
/// Deliberately carries NO timestamp: swift-kurrentdb's `RecordedEvent` has no
/// server-side created-date, so any time this type could offer would be
/// capture time masquerading as event time. Event time must come from the
/// event's own payload — see `decodeOccurred()`.
public struct ForwardedRecord: Sendable {
    public let eventType: String
    public let streamName: String
    public let eventId: String
    public let data: Data

    public init(eventType: String, streamName: String, eventId: String, data: Data) {
        self.eventType = eventType
        self.streamName = streamName
        self.eventId = eventId
        self.data = data
    }

    /// Decodes the payload. A decode failure is `ForwardingError.permanent`:
    /// bytes that don't fit the shape today won't fit on redelivery either.
    public func decodeBody<T: Decodable>(_ type: T.Type) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ForwardingError.permanent(
                reason: "decoding \(T.self) from \(eventType) (\(eventId)) failed: \(error)")
        }
    }

    /// Reads the event's own `occurred` timestamp — every DDDKit-generated
    /// `DomainEvent` carries one, encoded with a plain `JSONEncoder`
    /// (`.deferredToDate`), which is why this uses a matching plain decoder.
    /// Throws `.permanent` when absent: an event with no time will never grow
    /// one on redelivery.
    public func decodeOccurred() throws -> Date {
        struct TimeEnvelope: Decodable { let occurred: Date }
        do {
            return try JSONDecoder().decode(TimeEnvelope.self, from: data).occurred
        } catch {
            throw ForwardingError.permanent(
                reason: "\(eventType) (\(eventId)) carries no decodable `occurred`: \(error)")
        }
    }
}
