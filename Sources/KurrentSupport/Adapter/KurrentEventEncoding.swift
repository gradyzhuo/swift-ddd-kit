//
//  KurrentEventEncoding.swift
//  KurrentSupport
//
//  How domain events become `EventData`, shared by `KurrentStorageCoordinator.append`
//  and the unit-of-work path so both store the same bytes.
//

import DDDCore
import EventSourcing
import Foundation
import KurrentDB

/// Encodes `events` for KurrentDB: each event becomes JSON `EventData` with its own id
/// and `eventType`, carrying `metadata` JSON-encoded as its `customMetadata`.
///
/// - Returns: The encoded events and the metadata bytes they carry; `nil` metadata
///   gives `nil` bytes and events without `customMetadata`.
/// - Throws: The `JSONEncoder` error when `metadata` cannot be encoded.
package func encodeForKurrent<Metadata: EventMetadata>(
    events: [any DomainEvent],
    metadata: Metadata?
) throws -> (events: [EventData], metadataBytes: Data?) {
    let encoder = JSONEncoder()
    let metadataBytes: Data? = try metadata.map { try encoder.encode($0) }
    // `.bytes` stores the encoder's output unchanged, as 2.x did: the JSON rules apply where
    // they always did (`EventRecord(eventData:)` on the multi-stream path), and a
    // `JSONEncoder` result is never empty, the one thing `.bytes` refuses.
    let customMetadata = try metadataBytes.map {
        try KurrentDB.CustomMetadata(data: $0, format: .bytes)
    }
    let encodedEvents = events.map { event in
        if let customMetadata {
            EventData(id: event.id, eventType: event.eventType, model: event, customMetadata: customMetadata)
        } else {
            EventData(id: event.id, eventType: event.eventType, model: event)
        }
    }
    return (events: encodedEvents, metadataBytes: metadataBytes)
}
