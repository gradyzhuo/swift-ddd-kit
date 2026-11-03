//
//  KurrentAppendErrorMapping.swift
//  KurrentSupport
//
//  The `EventStore` contract's errors for a failed single-stream append, shared by
//  `KurrentStorageCoordinator.append` and the unit-of-work commit of one stream.
//

import DDDCore
import KurrentDB

/// Maps an error thrown by `EventStoreClient.append(events:toStream:category:expectedRevision:)`
/// for the stream of `id`:
/// - a wrong expected revision (`KurrentError.wrongExpectedVersion` from a live client,
///   `EventStoreClientError.wrongExpectedRevision` from the in-memory one) →
///   `DDDError.commitConflict(id:expected:actual:)`;
/// - `KurrentError.resourceDeleted` (the stream was tombstoned) → `DDDError.streamPurged(id:)`;
/// - anything else is returned unchanged.
///
/// - Parameter expected: The revision the append expected; `nil` for no stream.
package func mapSingleStreamAppendError(_ error: any Error, id: String, expected: UInt64?) -> any Error {
    switch error {
    case let KurrentError.wrongExpectedVersion(_, current):
        let actual: UInt64? = switch current {
            case .noStream: nil
            case let .revision(revision): revision
        }
        return DDDError.commitConflict(id: id, expected: expected, actual: actual)
    case KurrentError.resourceDeleted:
        return DDDError.streamPurged(id: id)
    case let EventStoreClientError.wrongExpectedRevision(current):
        return DDDError.commitConflict(id: id, expected: expected, actual: current)
    default:
        return error
    }
}
