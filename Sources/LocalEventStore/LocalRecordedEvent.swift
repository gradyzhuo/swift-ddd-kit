//
//  LocalRecordedEvent.swift
//  DDDKit
//

import EventSourcing
import Foundation

/// One stored record as the `EventTypeMapper` sees it.
struct LocalRecordedEvent: RecordedEventLike {
    let id: UUID
    let eventType: String
    let revision: UInt64
    let customMetadata: Data
    let streamName: String
    let payload: Data

    init(record: StreamFile.Record, revision: UInt64, streamName: String) {
        self.id = record.eventId
        self.eventType = record.eventType
        self.revision = revision
        self.customMetadata = record.metadata ?? Data()
        self.streamName = streamName
        self.payload = record.payload
    }

    func decode<T: Decodable>(to type: T.Type) throws -> T? {
        try JSONDecoder().decode(type, from: payload)
    }
}
