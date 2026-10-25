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
public actor PersistentEventStore<StreamNaming: EventStreamNaming, Metadata: EventMetadata> {
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
}
