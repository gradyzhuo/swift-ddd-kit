import KurrentDB
import Foundation

extension RecordedEvent {
    /// Returns the Swift type name encoded in the event's metadata, when the
    /// application uses `CustomMetadata` as its `EventMetadata` schema.
    ///
    /// Falls back to `self.eventType` (the KurrentDB-native event type field)
    /// when:
    /// - the app uses a different `EventMetadata` schema, OR
    /// - the event was written with no ambient metadata, OR
    /// - the `customMetadata` bytes are not a valid `CustomMetadata` JSON.
    ///
    /// The fallback path is the common case for apps that don't use
    /// `CustomMetadata` — they rely on the KurrentDB-native `eventType`
    /// (populated from `DomainEvent.eventType` at write time) for type
    /// resolution in generated mappers.
    public var mappingClassName: String {
        let decoder = JSONDecoder()
        do {
            let customMetadata = try decoder.decode(CustomMetadata.self, from: self.customMetadata)
            return customMetadata.className
        } catch {
            return self.eventType
        }
    }
    
    public var userId: String? {
        let decoder = JSONDecoder()
        let customMetadata = try? decoder.decode(CustomMetadata.self, from: self.customMetadata)
        return customMetadata?.external?["userId"]
    }
}
