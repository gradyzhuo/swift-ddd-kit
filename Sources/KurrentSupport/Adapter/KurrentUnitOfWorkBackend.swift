//
//  KurrentUnitOfWorkBackend.swift
//  KurrentSupport
//
//  Collects the appends `KurrentStorageCoordinator` makes inside a unit of work, one
//  batch per stream, and writes them when the scope commits.
//

import DDDCore
import EventSourcing
import Foundation
import KurrentDB
import Logging
import Synchronization

/// The unit-of-work backend for KurrentDB: stages one batch per stream and commits them
/// together. One stream commits through the single-stream `append` (same behaviour and
/// errors as an append outside a scope); two or more commit through one atomic
/// `appendAtomically` call.
package final class KurrentUnitOfWorkBackend: UnitOfWorkBackend {
    /// One stream's staged events.
    private struct Batch {
        /// The aggregate id the stream belongs to, reported in errors.
        let id: String
        let stream: String
        let category: String
        /// The first stage's expected revision: `.noStream` or `.at(_:)`.
        let expectedRevision: StreamRevision
        /// The revision the first staged event will get.
        let firstRevision: UInt64
        var events: [EventData]
        /// The revision the last staged event will get.
        var predictedTail: UInt64

        /// `expectedRevision` as the `EventStore` contract reports it: `nil` for no stream.
        var expectedVersion: UInt64? {
            guard case let .at(revision) = expectedRevision else { return nil }
            return revision
        }
    }

    private struct State {
        var batches: [String: Batch] = [:]
        /// Stream names in the order they were first staged, so commit order is deterministic.
        var streamOrder: [String] = []
        var committed = false
    }

    private let client: any EventStoreClient
    private let state = Mutex(State())
    private let logger: Logger

    /// - Parameter client: The client `commit()` writes through.
    package convenience init(client: any EventStoreClient) {
        self.init(client: client, logger: Logger(label: "KurrentUnitOfWorkBackend"))
    }

    /// - Parameters:
    ///   - client: The client `commit()` writes through.
    ///   - logger: Where `commit()` warns about a returned revision that differs from the
    ///     predicted one.
    package init(client: any EventStoreClient, logger: Logger) {
        self.client = client
        self.logger = logger
    }

    /// Stages `events` for `stream` and returns the predicted tail revision: the revision
    /// the last of them will get (`.noStream` → `count - 1`, `.at(n)` → `n + count`).
    ///
    /// A second stage on the same stream must expect the tail the previous one predicted;
    /// its events then join that stream's batch, which keeps the first expected revision.
    ///
    /// - Parameter id: The aggregate id `stream` belongs to, reported in errors.
    /// - Throws: `DDDError.commitConflict(id:expected:actual:)` with the predicted tail as
    ///   `actual` when a second stage expects anything else; `DDDError.operationNotAllow`
    ///   for no events, for `.any` or `.streamExists`, for a tail beyond `UInt64.max`, and
    ///   once `commit()` has started.
    package func stage(
        id: String,
        stream: String,
        category: String,
        expectedRevision: StreamRevision,
        events: [EventData]
    ) throws -> UInt64 {
        try state.withLock { state in
            guard !state.committed else { throw Self.alreadyCommitted(operation: "stage") }
            guard !events.isEmpty else {
                throw DDDError.operationNotAllow(operation: "stage", reason: "there are no events to stage for \(stream)")
            }
            let expected: UInt64?
            switch expectedRevision {
            case .noStream:
                expected = nil
            case let .at(revision):
                expected = revision
            case .any, .streamExists:
                throw DDDError.operationNotAllow(
                    operation: "stage",
                    reason: "a unit of work needs an exact expected revision (.noStream or .at), got \(expectedRevision) for \(stream)"
                )
            }
            // The events get revisions 0 ... count-1 on a new stream, n+1 ... n+count after `.at(n)`.
            let count = UInt64(events.count)
            let (tail, overflow) = expected.map { $0.addingReportingOverflow(count) } ?? (count - 1, false)
            guard !overflow else {
                throw DDDError.operationNotAllow(
                    operation: "stage",
                    reason: "\(count) events after revision \(expectedRevision) of \(stream) go beyond UInt64.max"
                )
            }

            guard var batch = state.batches[stream] else {
                state.batches[stream] = Batch(
                    id: id,
                    stream: stream,
                    category: category,
                    expectedRevision: expectedRevision,
                    firstRevision: tail - (count - 1),
                    events: events,
                    predictedTail: tail
                )
                state.streamOrder.append(stream)
                return tail
            }
            guard expected == batch.predictedTail else {
                throw DDDError.commitConflict(id: id, expected: expected, actual: batch.predictedTail)
            }
            batch.events.append(contentsOf: events)
            batch.predictedTail = tail
            state.batches[stream] = batch
            return tail
        }
    }

    /// The events staged for `stream` and the revision the first of them will get
    /// (`.noStream` → 0, `.at(n)` → `n + 1`), or `nil` when nothing is staged for it.
    ///
    /// - Throws: `DDDError.operationNotAllow(operation: "stage", …)` once `commit()` has
    ///   started, the same error `stage` throws then.
    package func stagedEvents(stream: String) throws -> (firstRevision: UInt64, events: [EventData])? {
        try state.withLock { state in
            guard !state.committed else { throw Self.alreadyCommitted(operation: "stage") }
            return state.batches[stream].map { (firstRevision: $0.firstRevision, events: $0.events) }
        }
    }

    /// Writes every staged batch: nothing for none, the single-stream `append` for one,
    /// one `appendAtomically` call for more. Ends the backend first, whatever the outcome:
    /// later `stage`, `stagedEvents` and `commit` calls throw.
    ///
    /// A returned revision that differs from the predicted tail is logged, not thrown: the
    /// events are stored, and the server's revision is the true one.
    ///
    /// - Throws: `DDDError.commitConflict` when an expected revision did not hold and
    ///   `DDDError.streamPurged` for a tombstoned stream (nothing was written for either);
    ///   `DDDError.operationNotAllow` when the server does not support `AppendRecords`;
    ///   any other client error unchanged, `EventStoreClientError.atomicAppendUnsupported`
    ///   included.
    package func commit() async throws {
        let batches = try state.withLock { state in
            guard !state.committed else { throw Self.alreadyCommitted(operation: "commit") }
            state.committed = true
            let batches = state.streamOrder.compactMap { state.batches[$0] }
            state.batches = [:]
            state.streamOrder = []
            return batches
        }

        switch batches.count {
        case 0:
            return
        case 1:
            let batch = batches[0]
            let revision: UInt64?
            do {
                revision = try await client.append(
                    events: batch.events,
                    toStream: batch.stream,
                    category: batch.category,
                    expectedRevision: batch.expectedRevision
                )
            } catch {
                throw mapSingleStreamAppendError(error, id: batch.id, expected: batch.expectedVersion)
            }
            warnIfUnpredicted(batch, returned: revision)
        default:
            let results: [StreamBatchResult]
            do {
                results = try await client.appendAtomically(batches.map {
                    StreamBatch(stream: $0.stream, category: $0.category, expectedRevision: $0.expectedRevision, events: $0.events)
                })
            } catch {
                throw Self.mapAtomicAppendError(error, batches: batches)
            }
            let returned = Dictionary(results.map { ($0.stream, $0.revision) }, uniquingKeysWith: { first, _ in first })
            for batch in batches {
                warnIfUnpredicted(batch, returned: returned[batch.stream])
            }
        }
    }

    private func warnIfUnpredicted(_ batch: Batch, returned: UInt64?) {
        guard returned != batch.predictedTail else { return }
        logger.warning(
            "Committed \(batch.stream): predicted revision \(batch.predictedTail), server returned \(returned.map(String.init) ?? "no revision")"
        )
    }

    /// Maps an `appendAtomically` error to the `EventStore` contract's errors, naming each
    /// stream by its batch's id. An error that names a stream no batch writes, or an empty
    /// violation list, is returned unchanged.
    private static func mapAtomicAppendError(_ error: any Error, batches: [Batch]) -> any Error {
        switch error {
        case let EventStoreClientError.consistencyViolations(violations):
            let conflicts = violations.compactMap { violation in
                batches.first { $0.stream == violation.stream }.map {
                    DDDError.CommitConflict(id: $0.id, expected: $0.expectedVersion, actual: violation.current)
                }
            }
            guard !conflicts.isEmpty, conflicts.count == violations.count else { return error }
            return DDDError.commitConflict(conflicts: conflicts)
        case let KurrentError.resourceDeleted(resource):
            guard let batch = batches.first(where: { $0.stream == resource }) else { return error }
            return DDDError.streamPurged(id: batch.id)
        case KurrentError.unsupportedFeature:
            return DDDError.operationNotAllow(operation: "commit", reason: "server does not support AppendRecords (KurrentDB 26.1+)")
        default:
            return error
        }
    }

    private static func alreadyCommitted(operation: String) -> DDDError {
        DDDError.operationNotAllow(operation: operation, reason: "unit of work already committed")
    }
}
