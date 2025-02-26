import EventStoreDB
import Foundation

extension RecordedEvent {
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
        return customMetadata?.userId
    }
}
