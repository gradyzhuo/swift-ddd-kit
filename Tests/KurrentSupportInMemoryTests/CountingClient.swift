import Foundation
import KurrentDB
import KurrentSupport
import KurrentSupportInMemory
import Synchronization

/// Forwards every call to a wrapped `InMemoryEventStoreClient`, counting `append` and
/// `appendAtomically` calls and recording the streams each `appendAtomically` call receives.
/// Optionally adds `revisionOffset` to the revisions both append methods return, withholds
/// one stream's revision, makes both throw `errorToThrow` without forwarding, parks both
/// on `gate` until the test lets them go on, or makes both check for cancellation.
final class CountingClient: EventStoreClient {
    /// Where an append checks for cancellation, as a client whose call is cancelled does.
    enum CancellationCheck: Sendable, CaseIterable {
        /// Before forwarding: a cancelled call writes nothing.
        case beforeWrite
        /// After forwarding: the write lands, and the call still throws `CancellationError`,
        /// like a server that committed before the cancelled client got its answer.
        case afterWrite
    }

    let wrapped: InMemoryEventStoreClient
    private let revisionOffset: UInt64
    private let withheldRevisionStream: String?
    private let errorToThrow: (any Error)?
    private let gate: AsyncStream<CheckedContinuation<Void, Never>>.Continuation?
    private let cancellationCheck: CancellationCheck?
    private let calls = Mutex<[String: Int]>([:])
    private let atomicBatchStreams = Mutex<[[String]]>([])

    /// - Parameter withholdingRevisionOf: A stream whose events are still written but whose
    ///   revision is not reported: `append` returns nil for it and `appendAtomically` leaves
    ///   it out of its results.
    /// - Parameter gate: When set, each `append` / `appendAtomically` call, once counted,
    ///   yields a continuation to `gate` and waits until the test resumes it, so the test
    ///   knows the call is in flight and controls when it goes on. Once the test finishes
    ///   `gate`, later calls go straight on.
    /// - Parameter cancellationCheck: When set, each `append` / `appendAtomically` call, once
    ///   past `gate`, throws `CancellationError` if its task is cancelled, before or after
    ///   forwarding.
    init(
        wrapping wrapped: InMemoryEventStoreClient,
        revisionOffset: UInt64 = 0,
        withholdingRevisionOf withheldRevisionStream: String? = nil,
        errorToThrow: (any Error)? = nil,
        gate: AsyncStream<CheckedContinuation<Void, Never>>.Continuation? = nil,
        cancellationCheck: CancellationCheck? = nil
    ) {
        self.wrapped = wrapped
        self.revisionOffset = revisionOffset
        self.withheldRevisionStream = withheldRevisionStream
        self.errorToThrow = errorToThrow
        self.gate = gate
        self.cancellationCheck = cancellationCheck
    }

    private func checkCancellation(_ point: CancellationCheck) throws {
        if cancellationCheck == point { try Task.checkCancellation() }
    }

    /// How many times `append(events:toStream:category:expectedRevision:)` was called.
    var appendCount: Int { calls.withLock { $0["append", default: 0] } }

    /// How many times `appendAtomically(_:)` was called.
    var appendAtomicallyCount: Int { calls.withLock { $0["appendAtomically", default: 0] } }

    /// The streams of each `appendAtomically(_:)` call's batches, in the order the call received them.
    var appendAtomicallyStreams: [[String]] { atomicBatchStreams.withLock { $0 } }

    private func record(_ method: String) {
        calls.withLock { $0[method, default: 0] += 1 }
    }

    /// Waits on `gate`, if any, until the test resumes the yielded continuation.
    private func passGate() async {
        guard let gate else { return }
        await withCheckedContinuation { continuation in
            if case .terminated = gate.yield(continuation) {
                continuation.resume()
            }
        }
    }

    var identity: ObjectIdentifier { wrapped.identity }

    func append(events: [EventData], toStream name: String, category: String, expectedRevision: StreamRevision) async throws -> UInt64? {
        record("append")
        await passGate()
        if let errorToThrow { throw errorToThrow }
        try checkCancellation(.beforeWrite)
        let revision = try await wrapped.append(events: events, toStream: name, category: category, expectedRevision: expectedRevision)
        try checkCancellation(.afterWrite)
        guard name != withheldRevisionStream else { return nil }
        return revision.map { $0 + revisionOffset }
    }

    func appendAtomically(_ batches: [StreamBatch]) async throws -> [StreamBatchResult] {
        record("appendAtomically")
        atomicBatchStreams.withLock { $0.append(batches.map(\.stream)) }
        await passGate()
        if let errorToThrow { throw errorToThrow }
        try checkCancellation(.beforeWrite)
        let results = try await wrapped.appendAtomically(batches)
        try checkCancellation(.afterWrite)
        return results
            .filter { $0.stream != withheldRevisionStream }
            .map { StreamBatchResult(stream: $0.stream, revision: $0.revision + revisionOffset) }
    }

    func readStream(name: String, from revision: RevisionCursor, resolveLinks: Bool) async throws -> [any RecordedEventLike] {
        try await wrapped.readStream(name: name, from: revision, resolveLinks: resolveLinks)
    }

    func deleteStream(name: String, expectedRevision: StreamRevision) async throws {
        try await wrapped.deleteStream(name: name, expectedRevision: expectedRevision)
    }

    func tombstoneStream(name: String) async throws {
        try await wrapped.tombstoneStream(name: name)
    }

    func subscribePersistent(stream: String, group: String) async throws -> any PersistentSubscriptionSession {
        try await wrapped.subscribePersistent(stream: stream, group: group)
    }

    func ensurePersistentSubscription(stream: String, group: String, settings: PersistentSubscriptionSettings) async throws {
        try await wrapped.ensurePersistentSubscription(stream: stream, group: group, settings: settings)
    }

    func deletePersistentSubscription(stream: String, group: String) async throws {
        try await wrapped.deletePersistentSubscription(stream: stream, group: group)
    }
}

/// The `KurrentError` swift-kurrentdb throws before sending a call the server lacks
/// (here: AppendRecords on a server older than KurrentDB 26.1).
let appendRecordsUnsupported = KurrentError.unsupportedFeature(
    .init(fullyQualifiedService: "kurrentdb.protocol.v2.streams.StreamsService", method: "AppendSession")
)
