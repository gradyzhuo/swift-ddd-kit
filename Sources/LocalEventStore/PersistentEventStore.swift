//
//  PersistentEventStore.swift
//  DDDKit
//

import DDDCore
import EventSourcing
import Foundation
import Logging

/// An `EventStore` backed by one directory: one JSON file per stream, replaced
/// atomically on every write, so a process crash leaves each file either old or new.
///
/// - One open instance per directory (`open` fails with `.occupied` otherwise).
///   Share that instance between the repository and the projectors that read it.
/// - Not durable across power loss or an OS crash: atomic writes are not fsynced,
///   so the latest writes can be lost and a just-replaced file can read back
///   corrupted (`storeCorrupted` for that stream only; `purge` clears it but
///   leaves the id unwritable).
/// - Keep the directory inside the app's own container (e.g. Application Support).
///   Shared containers, cloud-synced folders and network file systems are not
///   supported.
/// - Every append rewrites the whole stream file; meant for aggregate streams with
///   a bounded number of events.
public actor PersistentEventStore<StreamNaming: EventStreamNaming, Metadata: EventMetadata>: EventStore {
    let directory: URL
    let eventMapper: any EventTypeMapper
    let logger = Logger(label: "PersistentEventStore")
    /// `nil` once closed.
    var lockDescriptor: Int32?

    private init(directory: URL, eventMapper: any EventTypeMapper, lockDescriptor: Int32) {
        self.directory = directory
        self.eventMapper = eventMapper
        self.lockDescriptor = lockDescriptor
    }

    deinit {
        if let lockDescriptor {
            releaseDirectoryLock(lockDescriptor)
        }
    }

    /// Opens (creating it if needed) the store in `directory`.
    ///
    /// - Throws: `DDDError.storeUnavailable` with `.invalidLocation` when `directory`
    ///   is not a file URL or is a regular file, `.occupied` when another instance has
    ///   it open, `.io` when it cannot be created or locked.
    public static func open(directory: URL, eventMapper: any EventTypeMapper) throws -> PersistentEventStore {
        guard directory.isFileURL else {
            throw DDDError.storeUnavailable(reason: .invalidLocation, path: directory.absoluteString)
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw DDDError.storeUnavailable(reason: .invalidLocation, path: directory.path)
            }
        } else {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw DDDError.storeUnavailable(reason: .io, path: directory.path, detail: "\(error)")
            }
        }
        let descriptor = try acquireDirectoryLock(in: directory)
        return PersistentEventStore(directory: directory, eventMapper: eventMapper, lockDescriptor: descriptor)
    }

    /// Releases the directory. Idempotent; every later operation throws
    /// `storeUnavailable(reason: .closed)`.
    public func close() {
        guard let descriptor = lockDescriptor else { return }
        lockDescriptor = nil
        releaseDirectoryLock(descriptor)
    }

    // MARK: - EventStore

    public func fetchEvents(byId id: String) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)? {
        try ensureOpen()
        let stream = StreamNaming.getStreamName(id: id)
        guard let file = try load(stream: stream), !file.purged else { return nil }
        let mapped = map(file.records[...], stream: stream)
        guard let latestRevision = mapped.last?.revision else { return nil }
        return (events: mapped.map(\.event), latestRevision: latestRevision)
    }

    public func fetchEvents(byId id: String, afterRevision revision: UInt64) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)? {
        try ensureOpen()
        let stream = StreamNaming.getStreamName(id: id)
        guard let file = try load(stream: stream), !file.purged else { return nil }
        // Compare in UInt64 first: `Int(revision) + 1` traps for revisions near UInt64.max.
        let start = revision < UInt64(file.records.count) ? Int(revision) + 1 : file.records.count
        let mapped = map(file.records[start...], stream: stream)
        guard let latestRevision = mapped.last?.revision else {
            return (events: [], latestRevision: revision)
        }
        return (events: mapped.map(\.event), latestRevision: latestRevision)
    }

    public func append(
        events: [any DomainEvent],
        byId id: String,
        version: UInt64?,
        metadata: Metadata?
    ) async throws -> UInt64? {
        guard !events.isEmpty else { return nil }
        try ensureOpen()
        let stream = StreamNaming.getStreamName(id: id)
        var file = try load(stream: stream) ?? StreamFile(stream: stream)
        guard !file.purged else { throw DDDError.streamPurged(id: id) }

        let tail: UInt64? = file.records.isEmpty ? nil : UInt64(file.records.count - 1)
        guard tail == version else {
            if let replayed = idempotentRevision(of: events.map({ $0.id }), in: file.records.map(\.eventId), expected: version) {
                return replayed
            }
            throw DDDError.commitConflict(id: id, expected: version, actual: tail)
        }

        let encoder = JSONEncoder()
        let metadataBytes: Data? = try metadata.map { try encoder.encode($0) }
        let records = try events.map { event in
            StreamFile.Record(
                eventId: event.id,
                eventType: event.eventType,
                payload: try encoder.encode(event),
                metadata: metadataBytes
            )
        }
        file.records.append(contentsOf: records)
        try write(file)
        return UInt64(file.records.count - 1)
    }

    /// Makes the id permanently unwritable and drops its events from the stream
    /// file. Logical deletion only: earlier temporary files or freed disk blocks may
    /// still hold the bytes. Also the way to clear a corrupted stream.
    public func purge(byId id: String) async throws {
        try ensureOpen()
        let stream = StreamNaming.getStreamName(id: id)
        try write(StreamFile(stream: stream, purged: true))
    }

    // MARK: - File access

    private func ensureOpen() throws {
        guard lockDescriptor != nil else {
            throw DDDError.storeUnavailable(reason: .closed, path: directory.path)
        }
    }

    private func fileURL(forStream stream: String) throws -> URL {
        directory.appendingPathComponent(try StreamFile.fileName(forStream: stream), isDirectory: false)
    }

    /// The decoded file, or `nil` when it does not exist.
    private func load(stream: String) throws -> StreamFile? {
        let url = try fileURL(forStream: stream)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw DDDError.storeUnavailable(reason: .io, path: url.path, detail: "\(error)")
        }
        let file: StreamFile
        do {
            file = try JSONDecoder().decode(StreamFile.self, from: data)
        } catch {
            throw DDDError.storeCorrupted(stream: stream)
        }
        guard file.formatVersion == StreamFile.currentFormatVersion, file.stream == stream else {
            throw DDDError.storeCorrupted(stream: stream)
        }
        return file
    }

    /// Replaces the stream's file atomically; on failure the old file stays.
    private func write(_ file: StreamFile) throws {
        let url = try fileURL(forStream: file.stream)
        let data = try StreamFile.encode(file)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw DDDError.storeUnavailable(reason: .io, path: url.path, detail: "\(error)")
        }
    }

    /// Maps records through `eventMapper`, skipping those it returns `nil` for or
    /// throws on. Revisions are the records' indices in the stream.
    private func map(
        _ records: ArraySlice<StreamFile.Record>, stream: String
    ) -> [(event: any DomainEvent, revision: UInt64)] {
        var mapped: [(event: any DomainEvent, revision: UInt64)] = []
        for (index, record) in zip(records.indices, records) {
            let revision = UInt64(index)
            let recorded = LocalRecordedEvent(record: record, revision: revision, streamName: stream)
            do {
                if let event = try eventMapper.mapping(eventData: recorded) {
                    mapped.append((event: event, revision: revision))
                }
            } catch {
                logger.warning("skipped event \(record.eventId) at revision \(revision) of \(stream): \(error)")
            }
        }
        return mapped
    }
}
