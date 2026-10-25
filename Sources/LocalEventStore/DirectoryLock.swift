//
//  DirectoryLock.swift
//  DDDKit
//

import DDDCore
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Takes an exclusive, non-blocking `flock` on `<directory>/.lock` and returns the
/// descriptor. `flock` belongs to the open file description, so a second call for
/// the same directory fails even inside the same process.
func acquireDirectoryLock(in directory: URL) throws -> Int32 {
    let lockURL = directory.appendingPathComponent(".lock")
    let descriptor = lockURL.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return -1 }
        return open(path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o644)
    }
    guard descriptor >= 0 else {
        throw DDDError.storeUnavailable(reason: .io, path: lockURL.path, detail: "open failed, errno \(errno)")
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        let code = errno
        _ = close(descriptor)
        let reason: DDDError.StoreUnavailableReason = code == EWOULDBLOCK ? .occupied : .io
        throw DDDError.storeUnavailable(reason: reason, path: directory.path, detail: "flock failed, errno \(code)")
    }
    return descriptor
}

/// Closes the lock descriptor, which releases the `flock`.
func releaseDirectoryLock(_ descriptor: Int32) {
    _ = close(descriptor)
}
