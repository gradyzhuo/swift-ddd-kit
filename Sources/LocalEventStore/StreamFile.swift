//
//  StreamFile.swift
//  DDDKit
//

import DDDCore
import Foundation

/// The on-disk content of one stream: `<directory>/<StreamFile.fileName(forStream:)>`.
/// A record's revision is its index in `records`.
struct StreamFile: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1
    /// File names are 2 hex digits per byte plus `.json`; 120 bytes keeps them under
    /// the common 255-byte file-name limit.
    static let maxStreamNameBytes = 120

    struct Record: Codable, Equatable, Sendable {
        var eventId: UUID
        var eventType: String
        /// The event exactly as `JSONEncoder` produced it at append time.
        var payload: Data
        /// The batch's encoded metadata; omitted when the batch had none.
        var metadata: Data?
    }

    var formatVersion: Int
    var stream: String
    var purged: Bool
    var records: [Record]

    init(stream: String, purged: Bool = false, records: [Record] = []) {
        self.formatVersion = Self.currentFormatVersion
        self.stream = stream
        self.purged = purged
        self.records = records
    }

    /// Lowercase hex of the stream name's UTF-8 bytes, so names that differ only in
    /// case never share a file on a case-insensitive file system.
    static func fileName(forStream stream: String) throws -> String {
        let bytes = Array(stream.utf8)
        guard bytes.count <= maxStreamNameBytes else {
            throw DDDError.storeUnavailable(
                reason: .streamNameTooLong, path: stream,
                detail: "\(bytes.count) UTF-8 bytes, at most \(maxStreamNameBytes)")
        }
        let digits = Array("0123456789abcdef")
        var name = ""
        name.reserveCapacity(bytes.count * 2 + 5)
        for byte in bytes {
            name.append(digits[Int(byte >> 4)])
            name.append(digits[Int(byte & 0x0f)])
        }
        return name + ".json"
    }

    static func encode(_ file: StreamFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(file)
    }
}
