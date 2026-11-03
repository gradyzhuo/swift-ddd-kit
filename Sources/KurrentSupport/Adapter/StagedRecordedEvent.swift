//
//  StagedRecordedEvent.swift
//  KurrentSupport
//
//  An event staged inside a unit of work, read back before it is committed.
//

import EventSourcing
import Foundation
import KurrentDB

/// An event a unit of work has staged but not yet committed, shaped like a record read from
/// the server so `KurrentStorageCoordinator` maps it with the same `EventTypeMapper`.
struct StagedRecordedEvent: RecordedEventLike {
    let eventData: EventData
    /// The revision the event will get when the unit of work commits as predicted.
    let revision: UInt64
    let streamName: String

    var id: UUID { eventData.id }
    var eventType: String { eventData.eventType }
    /// The staged metadata bytes; empty when there are none, as on a server record.
    var customMetadata: Data { eventData.customMetadata ?? Data() }

    /// Decodes the payload with a default `JSONDecoder`, as `InMemoryEventStoreClient` does
    /// for the records it stores.
    func decode<T: Decodable>(to type: T.Type) throws -> T? {
        try JSONDecoder().decode(T.self, from: eventData.payload.data)
    }
}
