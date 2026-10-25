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
    // `errno` only describes the call that just failed, so it is captured right there.
    let (descriptor, openError) = lockURL.withUnsafeFileSystemRepresentation { path -> (Int32, Int32) in
        guard let path else { return (-1, EINVAL) }
        let descriptor = open(path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return (-1, errno) }
        return (descriptor, 0)
    }
    guard descriptor >= 0 else {
        throw DDDError.storeUnavailable(reason: .io, path: lockURL.path, detail: "open failed, errno \(openError)")
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
