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
    /// KurrentDB `customMetadata` as raw bytes — whatever the writing context's
    /// `EventMetadata` struct JSON-encoded to (see
    /// `docs/superpowers/specs/2026-05-15-ambient-context-and-pluggable-metadata-design.md`).
    /// `nil` when the write carried no metadata; swift-kurrentdb hands that back
    /// as an empty `Data`, which `init(from:)` normalises so "absent" has exactly
    /// one spelling. Raw rather than typed on purpose: this record is
    /// kit-agnostic and each rule picks its own schema via `decodeMetadata(_:)`.
    public let metadata: Data?

    public init(
        eventType: String,
        streamName: String,
        eventId: String,
        data: Data,
        metadata: Data? = nil
    ) {
        self.eventType = eventType
        self.streamName = streamName
        self.eventId = eventId
        self.data = data
        self.metadata = metadata
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

    /// `RecordedEvent.customMetadata` is a non-optional `Data` that is empty
    /// when nothing was written. Collapse that to `nil` so callers never have
    /// to ask "nil or empty?". Kept `static` and side-effect free so it is
    /// testable without constructing a `ReadEvent`.
    static func normalizedMetadata(_ bytes: Data) -> Data? {
        bytes.isEmpty ? nil : bytes
    }
}
