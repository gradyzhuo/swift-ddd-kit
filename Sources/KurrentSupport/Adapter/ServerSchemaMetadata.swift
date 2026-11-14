//
//  ServerSchemaMetadata.swift
//  KurrentSupport
//
//  KurrentDB adds `$schema.name` and `$schema.format` to the custom metadata of every
//  event written through AppendRecords, also to one written without metadata. Such an
//  event would read back with a JSON object of only those two keys where an event written
//  any other way (a v1 append, a staged event inside a unit of work, InMemoryEventStoreClient)
//  has empty bytes. `LiveEventStoreClient` hands it on with empty bytes instead.
//

import EventSourcing
import Foundation

/// Whether `bytes` is a non-empty JSON object whose every key starts with `$schema.`: what
/// the server stores for an event written through AppendRecords without custom metadata.
package func holdsOnlyServerSchemaKeys(_ bytes: Data) -> Bool {
    guard !bytes.isEmpty,
          let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
          !object.isEmpty
    else {
        return false
    }
    return object.keys.allSatisfy { $0.hasPrefix("$schema.") }
}

/// `record` unchanged, or, when its custom metadata holds only the server's `$schema.*`
/// keys, a record identical to it except for empty custom metadata.
package func withoutServerOnlyMetadata(_ record: any RecordedEventLike) -> any RecordedEventLike {
    holdsOnlyServerSchemaKeys(record.customMetadata) ? RecordWithoutMetadata(base: record) : record
}

/// Everything from `base` except the custom metadata, which is empty.
private struct RecordWithoutMetadata: RecordedEventLike {
    let base: any RecordedEventLike

    var id: UUID { base.id }
    var eventType: String { base.eventType }
    var revision: UInt64 { base.revision }
    var customMetadata: Data { Data() }
    var streamName: String { base.streamName }

    func decode<T: Decodable>(to type: T.Type) throws -> T? {
        try base.decode(to: type)
    }
}
