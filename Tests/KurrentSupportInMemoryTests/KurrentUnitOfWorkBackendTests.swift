import Testing
import Foundation
import KurrentDB
import DDDCore
import EventSourcing
import KurrentSupport
import KurrentSupportInMemory
import Logging

private struct Sample: Codable, Sendable {
    let text: String
}

private func sample(_ text: String) -> EventData {
    EventData(eventType: "Sample", model: Sample(text: text))
}

private func samples(_ texts: String...) -> [EventData] {
    texts.map(sample)
}

/// `stage` for a stream named `Order-<id>`.
@discardableResult
private func stage(
    _ backend: KurrentUnitOfWorkBackend,
    _ id: String,
    _ expectedRevision: StreamRevision,
    _ events: [EventData]
) throws -> UInt64 {
    try backend.stage(id: id, stream: "Order-\(id)", category: "Order", expectedRevision: expectedRevision, events: events)
}

private func storedIds(_ client: InMemoryEventStoreClient, _ stream: String) async throws -> [UUID] {
    try await client.readStream(name: stream, from: .start, resolveLinks: true).map(\.id)
}

private func storedRevisions(_ client: InMemoryEventStoreClient, _ stream: String) async throws -> [UInt64] {
    try await client.readStream(name: stream, from: .start, resolveLinks: true).map(\.revision)
}

private func expectNotWritten(_ client: InMemoryEventStoreClient, _ stream: String, sourceLocation: SourceLocation = #_sourceLocation) async {
    await #expect(throws: EventStoreClientError.streamNotFound, sourceLocation: sourceLocation) {
        _ = try await client.readStream(name: stream, from: .start, resolveLinks: true)
    }
}

/// The `DDDError` `body` throws; records an issue and returns nil when `body` throws
/// something else or nothing.
private func captureDDDError(
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> Void
) async -> DDDError? {
    do {
        try await body()
        Issue.record("expected a DDDError", sourceLocation: sourceLocation)
        return nil
    } catch let error as DDDError {
        return error
    } catch {
        Issue.record("expected a DDDError, got \(error)", sourceLocation: sourceLocation)
        return nil
    }
}

/// Like `captureDDDError`, and checks the error is `operationNotAllow(operation:)`.
private func captureOperationNotAllow(
    _ operation: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> Void
) async -> DDDError? {
    let error = await captureDDDError(sourceLocation: sourceLocation, body)
    #expect(error?.code == .aggregateOperationNotAllowed, sourceLocation: sourceLocation)
    #expect(error?.userInfos["operation"] as? String == operation, sourceLocation: sourceLocation)
    return error
}

/// The `KurrentError` swift-kurrentdb throws before sending a call the server lacks.
private let appendRecordsUnsupported = KurrentError.unsupportedFeature(
    .init(fullyQualifiedService: "kurrentdb.protocol.v2.streams.StreamsService", method: "AppendSession")
)

/// The warning `commit()` logs when the client reports `returned` for `stream` instead of
/// the predicted tail.
private func revisionWarning(_ stream: String, predicted: UInt64, returned: String) -> LogRecorder.Entry {
    .init(level: .warning, message: "Committed \(stream): predicted revision \(predicted), server returned \(returned)")
}

// MARK: - Event encoding fixtures

private struct Placed: DomainEvent, Equatable {
    typealias Metadata = [String: String]
    var id: UUID = .init()
    var occurred: Date = Date(timeIntervalSince1970: 1_700_000_000)
    var aggregateRootId: String
    var metadata: [String: String]? = nil
    var amount: Int
}

/// `bytes` parsed by `JSONSerialization` as a JSON object of strings; `nil` for no bytes or
/// anything else.
private func jsonStringObject(_ bytes: Data?) throws -> [String: String]? {
    guard let bytes else { return nil }
    return try JSONSerialization.jsonObject(with: bytes) as? [String: String]
}

@Suite("KurrentUnitOfWorkBackend")
struct KurrentUnitOfWorkBackendTests {

    // MARK: stage

    @Test("stage predicts the tail: .noStream + 3 events → 2, .at(4) + 1 event → 5")
    func stagePredictsTailForNewAndExistingStreams() throws {
        let backend = KurrentUnitOfWorkBackend(client: InMemoryEventStoreClient())
        let newEvents = samples("a1", "a2", "a3")
        let existingEvents = samples("b5")

        #expect(try stage(backend, "a", .noStream, newEvents) == 2)
        #expect(try stage(backend, "b", .at(4), existingEvents) == 5)

        let stagedNew = try #require(try backend.stagedEvents(stream: "Order-a"))
        #expect(stagedNew.firstRevision == 0)
        #expect(stagedNew.events.map(\.id) == newEvents.map(\.id))
        let stagedExisting = try #require(try backend.stagedEvents(stream: "Order-b"))
        #expect(stagedExisting.firstRevision == 5)
        #expect(stagedExisting.events.map(\.id) == existingEvents.map(\.id))
        #expect(try backend.stagedEvents(stream: "Order-unknown") == nil)
    }

    @Test("a second stage must expect the predicted tail; on a match it joins the batch, which keeps the first expected revision")
    func secondStageMustFollowPredictedTail() async throws {
        let client = InMemoryEventStoreClient()
        let backend = KurrentUnitOfWorkBackend(client: client)
        let first = samples("a1", "a2", "a3")
        let second = samples("a4")
        #expect(try stage(backend, "a", .noStream, first) == 2)

        let behind = await captureDDDError { try stage(backend, "a", .at(1), samples("x")) }
        #expect(behind?.commitConflicts == [DDDError.CommitConflict(id: "a", expected: 1, actual: 2)])
        let asNew = await captureDDDError { try stage(backend, "a", .noStream, samples("x")) }
        #expect(asNew?.commitConflicts == [DDDError.CommitConflict(id: "a", expected: nil, actual: 2)])

        #expect(try stage(backend, "a", .at(2), second) == 3)
        let staged = try #require(try backend.stagedEvents(stream: "Order-a"))
        #expect(staged.firstRevision == 0)
        #expect(staged.events.map(\.id) == (first + second).map(\.id))

        // The stream does not exist: the commit only succeeds because the batch still expects `.noStream`.
        try await backend.commit()
        #expect(try await storedIds(client, "Order-a") == (first + second).map(\.id))
        #expect(try await storedRevisions(client, "Order-a") == [0, 1, 2, 3])
    }

    @Test("stage rejects empty events, .any and .streamExists, and stages nothing")
    func stageRejectsEmptyAnyAndStreamExists() async throws {
        let backend = KurrentUnitOfWorkBackend(client: InMemoryEventStoreClient())

        _ = await captureOperationNotAllow("stage") { try stage(backend, "a", .noStream, []) }
        _ = await captureOperationNotAllow("stage") { try stage(backend, "a", .any, samples("a1")) }
        _ = await captureOperationNotAllow("stage") { try stage(backend, "a", .streamExists, samples("a1")) }

        #expect(try backend.stagedEvents(stream: "Order-a") == nil)
    }

    @Test("a predicted tail beyond UInt64 throws instead of trapping")
    func stageRejectsRevisionOverflow() async throws {
        let backend = KurrentUnitOfWorkBackend(client: InMemoryEventStoreClient())

        _ = await captureOperationNotAllow("stage") { try stage(backend, "a", .at(UInt64.max), samples("a1")) }
        _ = await captureOperationNotAllow("stage") { try stage(backend, "b", .at(UInt64.max - 1), samples("b1", "b2")) }

        #expect(try backend.stagedEvents(stream: "Order-a") == nil)
        #expect(try backend.stagedEvents(stream: "Order-b") == nil)
    }

    // MARK: commit

    @Test("commit with nothing staged calls the client not at all")
    func commitWithNoBatchesTouchesNothing() async throws {
        let client = CountingClient(wrapping: InMemoryEventStoreClient())
        let backend = KurrentUnitOfWorkBackend(client: client)

        try await backend.commit()

        #expect(client.appendCount == 0)
        #expect(client.appendAtomicallyCount == 0)
    }

    @Test("one stream commits through the plain single-stream append")
    func singleBatchUsesPlainAppend() async throws {
        let store = InMemoryEventStoreClient()
        let client = CountingClient(wrapping: store)
        let backend = KurrentUnitOfWorkBackend(client: client)
        let first = samples("a1")
        let second = samples("a2")
        try stage(backend, "a", .noStream, first)
        try stage(backend, "a", .at(0), second)

        try await backend.commit()

        #expect(client.appendCount == 1)
        #expect(client.appendAtomicallyCount == 0)
        #expect(try await storedIds(store, "Order-a") == (first + second).map(\.id))
    }

    @Test("two streams commit through one appendAtomically call")
    func twoBatchesUseAppendAtomically() async throws {
        let store = InMemoryEventStoreClient()
        _ = try await store.append(events: samples("b0"), toStream: "Order-b", category: "Order", expectedRevision: .noStream)
        let client = CountingClient(wrapping: store)
        let backend = KurrentUnitOfWorkBackend(client: client)
        let a = samples("a1", "a2")
        let b = samples("b1")
        try stage(backend, "a", .noStream, a)
        try stage(backend, "b", .at(0), b)

        try await backend.commit()

        #expect(client.appendCount == 0)
        #expect(client.appendAtomicallyCount == 1)
        #expect(try await storedIds(store, "Order-a") == a.map(\.id))
        #expect(try await storedRevisions(store, "Order-b") == [0, 1])
        #expect(try await storedIds(store, "Order-b").last == b[0].id)
    }

    @Test("appendAtomically gets the batches in the order their streams were first staged")
    func commitSendsBatchesInStagingOrder() async throws {
        let client = CountingClient(wrapping: InMemoryEventStoreClient())
        let backend = KurrentUnitOfWorkBackend(client: client)
        // Not sorted, and eight of them: batches taken in hash order would match by chance
        // about once in 40,000 runs (with three, once in six).
        let ids = ["z", "a", "m", "q", "c", "x", "f", "k"]
        for id in ids {
            try stage(backend, id, .noStream, samples("\(id)1"))
        }
        // Joins z's batch; z stays first.
        try stage(backend, "z", .at(0), samples("z2"))

        try await backend.commit()

        #expect(client.appendAtomicallyStreams == [ids.map { "Order-\($0)" }])
    }

    @Test("one stream at another revision becomes commitConflict for its id")
    func singleBatchConflictBecomesCommitConflict() async throws {
        let client = InMemoryEventStoreClient()
        _ = try await client.append(events: samples("a0"), toStream: "Order-a", category: "Order", expectedRevision: .noStream)
        let backend = KurrentUnitOfWorkBackend(client: client)
        try stage(backend, "a", .noStream, samples("a1"))

        let error = await captureDDDError { try await backend.commit() }

        #expect(error?.code == .commitConflict)
        #expect(error?.commitConflicts == [DDDError.CommitConflict(id: "a", expected: nil, actual: 0)])
        #expect(try await storedRevisions(client, "Order-a") == [0])
    }

    @Test("one stream staged at .at(1) while the server is at 3 → commitConflict(id, expected 1, actual 3)")
    func singleStreamConflictCarriesExpectedRevision() async throws {
        let client = InMemoryEventStoreClient()
        _ = try await client.append(events: samples("a0", "a1", "a2", "a3"), toStream: "Order-a", category: "Order", expectedRevision: .noStream)
        let backend = KurrentUnitOfWorkBackend(client: client)
        try stage(backend, "a", .at(1), samples("x"))

        let error = await captureDDDError { try await backend.commit() }

        #expect(error?.code == .commitConflict)
        #expect(error?.commitConflicts == [DDDError.CommitConflict(id: "a", expected: 1, actual: 3)])
        #expect(try await storedRevisions(client, "Order-a") == [0, 1, 2, 3])
    }

    @Test("one stream: unsupportedFeature is rethrown unchanged, since the single-stream append is not AppendRecords")
    func singleStreamUnsupportedFeatureIsRethrownUnchanged() async throws {
        let client = CountingClient(wrapping: InMemoryEventStoreClient(), errorToThrow: appendRecordsUnsupported)
        let backend = KurrentUnitOfWorkBackend(client: client)
        try stage(backend, "a", .noStream, samples("a1"))

        await #expect(throws: appendRecordsUnsupported) { try await backend.commit() }

        #expect(client.appendCount == 1)
        #expect(client.appendAtomicallyCount == 0)
    }

    @Test("consistency violations become commitConflict(conflicts:) with each stream's id; nothing is written")
    func consistencyViolationsBecomeCommitConflictWithIds() async throws {
        let client = InMemoryEventStoreClient()
        _ = try await client.append(events: samples("a0"), toStream: "Order-a", category: "Order", expectedRevision: .noStream)
        let backend = KurrentUnitOfWorkBackend(client: client)
        try stage(backend, "a", .noStream, samples("a1"))
        try stage(backend, "b", .noStream, samples("b1"))

        let error = await captureDDDError { try await backend.commit() }

        #expect(error?.code == .commitConflict)
        #expect(error?.commitConflicts == [DDDError.CommitConflict(id: "a", expected: nil, actual: 0)])
        #expect(try await storedRevisions(client, "Order-a") == [0])
        await expectNotWritten(client, "Order-b")
    }

    @Test("every conflicting stream is listed with its id and expected revision")
    func everyConflictListed() async throws {
        let client = InMemoryEventStoreClient()
        _ = try await client.append(events: samples("a0"), toStream: "Order-a", category: "Order", expectedRevision: .noStream)
        let backend = KurrentUnitOfWorkBackend(client: client)
        try stage(backend, "a", .noStream, samples("a1"))
        try stage(backend, "b", .at(3), samples("b4"))

        let error = await captureDDDError { try await backend.commit() }

        #expect(error?.commitConflicts == [
            DDDError.CommitConflict(id: "a", expected: nil, actual: 0),
            DDDError.CommitConflict(id: "b", expected: 3, actual: nil),
        ])
    }

    @Test("a tombstoned stream becomes streamPurged for its id; nothing is written", arguments: [false, true])
    func tombstonedBecomesStreamPurged(withSecondStream: Bool) async throws {
        let client = InMemoryEventStoreClient()
        try await client.tombstoneStream(name: "Order-t")
        let backend = KurrentUnitOfWorkBackend(client: client)
        if withSecondStream {
            try stage(backend, "u", .noStream, samples("u1"))
        }
        try stage(backend, "t", .noStream, samples("t1"))

        let error = await captureDDDError { try await backend.commit() }

        #expect(error?.code == .streamPurged)
        #expect(error?.userInfos["id"] as? String == "t")
        // Still tombstoned: nothing recreated it.
        await #expect(throws: KurrentError.resourceDeleted(resource: "Order-t")) {
            _ = try await client.readStream(name: "Order-t", from: .start, resolveLinks: true)
        }
        if withSecondStream {
            await expectNotWritten(client, "Order-u")
        }
    }

    @Test("a server without AppendRecords becomes operationNotAllow on commit")
    func unsupportedFeatureBecomesOperationNotAllow() async throws {
        let client = CountingClient(wrapping: InMemoryEventStoreClient(), errorToThrow: appendRecordsUnsupported)
        let backend = KurrentUnitOfWorkBackend(client: client)
        try stage(backend, "a", .noStream, samples("a1"))
        try stage(backend, "b", .noStream, samples("b1"))

        let error = await captureOperationNotAllow("commit") { try await backend.commit() }

        #expect(error?.userInfos["reason"] as? String == "server does not support AppendRecords (KurrentDB 26.1+)")
        #expect(client.appendAtomicallyCount == 1)
    }

    @Test(
        "client errors the backend cannot attribute to its batches are rethrown unchanged",
        arguments: [
            EventStoreClientError.consistencyViolations([]),
            .consistencyViolations([StreamConflict(stream: "Order-elsewhere", expected: .noStream, current: 0)]),
            .consistencyViolations([
                StreamConflict(stream: "Order-a", expected: .noStream, current: 0),
                StreamConflict(stream: "Order-elsewhere", expected: .noStream, current: 0),
            ]),
            .atomicAppendUnsupported,
            .wrongExpectedRevision(current: 0),
        ]
    )
    func unattributableClientErrorsAreRethrownUnchanged(error: EventStoreClientError) async throws {
        let client = CountingClient(wrapping: InMemoryEventStoreClient(), errorToThrow: error)
        let backend = KurrentUnitOfWorkBackend(client: client)
        try stage(backend, "a", .noStream, samples("a1"))
        try stage(backend, "b", .noStream, samples("b1"))

        await #expect(throws: error) { try await backend.commit() }
    }

    @Test("resourceDeleted for a stream no batch writes is rethrown unchanged")
    func resourceDeletedOfAnotherStreamIsRethrownUnchanged() async throws {
        let error = KurrentError.resourceDeleted(resource: "Order-elsewhere")
        let client = CountingClient(wrapping: InMemoryEventStoreClient(), errorToThrow: error)
        let backend = KurrentUnitOfWorkBackend(client: client)
        try stage(backend, "a", .noStream, samples("a1"))
        try stage(backend, "b", .noStream, samples("b1"))

        await #expect(throws: error) { try await backend.commit() }
    }

    @Test("returned revisions that match the prediction log no warning", arguments: [1, 2])
    func matchingRevisionsLogNothing(streamCount: Int) async throws {
        let store = InMemoryEventStoreClient()
        let recorder = LogRecorder()
        let backend = KurrentUnitOfWorkBackend(client: store, logger: recorder.logger)
        // Two events on a: its predicted tail (1) differs from its first revision (0).
        let batches = [(id: "a", events: samples("a1", "a2")), (id: "b", events: samples("b1"))].prefix(streamCount)
        for batch in batches {
            try stage(backend, batch.id, .noStream, batch.events)
        }

        try await backend.commit()

        #expect(recorder.warnings == [])
        for batch in batches {
            #expect(try await storedIds(store, "Order-\(batch.id)") == batch.events.map(\.id))
        }
    }

    @Test("returned revisions that differ from the prediction are logged, one warning per stream, not thrown", arguments: [1, 2])
    func revisionMismatchIsLoggedNotThrown(streamCount: Int) async throws {
        let store = InMemoryEventStoreClient()
        let recorder = LogRecorder()
        let backend = KurrentUnitOfWorkBackend(client: CountingClient(wrapping: store, revisionOffset: 10), logger: recorder.logger)
        // a is predicted at 0 and b at 1; the client reports each 10 higher.
        let batches = [(id: "a", events: samples("a1")), (id: "b", events: samples("b1", "b2"))].prefix(streamCount)
        for batch in batches {
            try stage(backend, batch.id, .noStream, batch.events)
        }

        try await backend.commit()

        let expected = [
            revisionWarning("Order-a", predicted: 0, returned: "10"),
            revisionWarning("Order-b", predicted: 1, returned: "11"),
        ]
        #expect(recorder.warnings == Array(expected.prefix(streamCount)))
        for batch in batches {
            #expect(try await storedIds(store, "Order-\(batch.id)") == batch.events.map(\.id))
        }
    }

    @Test(
        "a stream the client reports no revision for is logged, not thrown: append returns nil, or appendAtomically leaves it out",
        arguments: [1, 2]
    )
    func missingResultIsLoggedNotThrown(streamCount: Int) async throws {
        let store = InMemoryEventStoreClient()
        let recorder = LogRecorder()
        let batches = [(id: "a", events: samples("a1")), (id: "b", events: samples("b1", "b2"))].prefix(streamCount)
        let missing = try #require(batches.last)
        let client = CountingClient(wrapping: store, withholdingRevisionOf: "Order-\(missing.id)")
        let backend = KurrentUnitOfWorkBackend(client: client, logger: recorder.logger)
        for batch in batches {
            try stage(backend, batch.id, .noStream, batch.events)
        }

        try await backend.commit()

        #expect(recorder.warnings == [
            revisionWarning("Order-\(missing.id)", predicted: UInt64(missing.events.count - 1), returned: "no revision"),
        ])
        #expect(client.appendCount == (streamCount == 1 ? 1 : 0))
        #expect(client.appendAtomicallyCount == (streamCount == 1 ? 0 : 1))
        for batch in batches {
            #expect(try await storedIds(store, "Order-\(batch.id)") == batch.events.map(\.id))
        }
    }

    // MARK: after commit

    @Test("once committed, stage and stagedEvents throw operationNotAllow(\"stage\") and commit throws operationNotAllow(\"commit\")")
    func stageAfterCommitThrows() async throws {
        let client = InMemoryEventStoreClient()
        let backend = KurrentUnitOfWorkBackend(client: client)
        try stage(backend, "a", .noStream, samples("a1"))
        try await backend.commit()

        let staging = await captureOperationNotAllow("stage") { try stage(backend, "b", .noStream, samples("b1")) }
        #expect((staging?.userInfos["reason"] as? String)?.contains("already committed") == true)
        let reading = await captureOperationNotAllow("stage") { _ = try backend.stagedEvents(stream: "Order-a") }
        #expect((reading?.userInfos["reason"] as? String)?.contains("already committed") == true)
        _ = await captureOperationNotAllow("commit") { try await backend.commit() }

        await expectNotWritten(client, "Order-b")
    }

    @Test("a commit that failed still ends the backend")
    func stageAfterFailedCommitThrows() async throws {
        let backend = KurrentUnitOfWorkBackend(client: CountingClient(wrapping: InMemoryEventStoreClient(), errorToThrow: EventStoreClientError.atomicAppendUnsupported))
        try stage(backend, "a", .noStream, samples("a1"))
        try stage(backend, "b", .noStream, samples("b1"))
        await #expect(throws: EventStoreClientError.atomicAppendUnsupported) { try await backend.commit() }

        _ = await captureOperationNotAllow("stage") { try stage(backend, "c", .noStream, samples("c1")) }
        _ = await captureOperationNotAllow("stage") { _ = try backend.stagedEvents(stream: "Order-a") }
    }

    @Test(
        "commit ends the backend before it awaits the client: stage, stagedEvents and commit throw while the write is in flight",
        arguments: [1, 2]
    )
    func stageWhileCommitAwaitsClientThrows(streamCount: Int) async throws {
        let store = InMemoryEventStoreClient()
        let (parked, park) = AsyncStream.makeStream(of: CheckedContinuation<Void, Never>.self)
        let client = CountingClient(wrapping: store, gate: park)
        let backend = KurrentUnitOfWorkBackend(client: client)
        let batches = ["a", "b"].prefix(streamCount).map { (id: $0, events: samples("\($0)1")) }
        for batch in batches {
            try stage(backend, batch.id, .noStream, batch.events)
        }

        let committing = Task {
            // Ends the wait below even if commit never reaches the client, so a regression fails instead of hanging.
            defer { park.finish() }
            try await backend.commit()
        }
        var parkedAppends = parked.makeAsyncIterator()
        let inFlight = await parkedAppends.next()
        // Any later append goes straight on, so a regression that writes again fails instead of hanging.
        park.finish()
        let append = try #require(inFlight, "commit returned without calling the client")

        // The client append is in flight: the backend must already be ended.
        let staging = await captureOperationNotAllow("stage") { try stage(backend, "c", .noStream, samples("c1")) }
        #expect((staging?.userInfos["reason"] as? String)?.contains("already committed") == true)
        let reading = await captureOperationNotAllow("stage") { _ = try backend.stagedEvents(stream: "Order-a") }
        #expect((reading?.userInfos["reason"] as? String)?.contains("already committed") == true)
        let recommitting = await captureOperationNotAllow("commit") { try await backend.commit() }
        #expect((recommitting?.userInfos["reason"] as? String)?.contains("already committed") == true)

        append.resume()
        try await committing.value

        #expect(client.appendCount == (streamCount == 1 ? 1 : 0))
        #expect(client.appendAtomicallyCount == (streamCount == 1 ? 0 : 1))
        for batch in batches {
            #expect(try await storedIds(store, "Order-\(batch.id)") == batch.events.map(\.id))
        }
        await expectNotWritten(store, "Order-c")
    }

    @Test(
        "stagedEventsIfUncommitted gives what stagedEvents gives until the commit starts, then nil without throwing: while the write is in flight and after it succeeded or failed",
        arguments: [false, true]
    )
    func stagedEventsIfUncommittedIsNilOnceCommitStarted(commitFails: Bool) async throws {
        let store = InMemoryEventStoreClient()
        let (parked, park) = AsyncStream.makeStream(of: CheckedContinuation<Void, Never>.self)
        let client = CountingClient(
            wrapping: store,
            errorToThrow: commitFails ? EventStoreClientError.atomicAppendUnsupported : nil,
            gate: park
        )
        let backend = KurrentUnitOfWorkBackend(client: client)
        let events = samples("a1", "a2")
        try stage(backend, "a", .noStream, events)

        let staged = try #require(try backend.stagedEvents(stream: "Order-a"))
        let looked = try #require(backend.stagedEventsIfUncommitted(stream: "Order-a"))
        #expect(looked.firstRevision == staged.firstRevision)
        #expect(looked.events.map(\.id) == events.map(\.id))
        #expect(backend.stagedEventsIfUncommitted(stream: "Order-unknown") == nil)

        let committing = Task {
            // Ends the wait below even if commit never reaches the client, so a regression fails instead of hanging.
            defer { park.finish() }
            try await backend.commit()
        }
        var parkedAppends = parked.makeAsyncIterator()
        let inFlight = await parkedAppends.next()
        park.finish()
        let append = try #require(inFlight, "commit returned without calling the client")

        // The commit has started: a read that got this backend just before sees nothing staged.
        #expect(backend.stagedEventsIfUncommitted(stream: "Order-a") == nil)

        append.resume()
        if commitFails {
            await #expect(throws: EventStoreClientError.atomicAppendUnsupported) { try await committing.value }
        } else {
            try await committing.value
        }
        #expect(backend.stagedEventsIfUncommitted(stream: "Order-a") == nil)
    }

    // MARK: encodeForKurrent

    @Test("encodeForKurrent keeps each event's id, type and payload and carries the metadata as a JSON object; nil metadata carries no bytes")
    func encodeForKurrentWritesMetadataAsJSONObject() throws {
        let events = [Placed(aggregateRootId: "1", amount: 3), Placed(aggregateRootId: "1", amount: 5)]

        let encoded = try encodeForKurrent(events: events, metadata: CustomMetadata(operatorId: "operator-7"))

        #expect(encoded.events.map(\.id) == events.map(\.id))
        #expect(encoded.events.map(\.eventType) == events.map(\.eventType))
        for (eventData, event) in zip(encoded.events, events) {
            #expect(try JSONDecoder().decode(Placed.self, from: eventData.payload.data) == event)
            #expect(try jsonStringObject(eventData.customMetadata) == ["operatorId": "operator-7"])
        }
        #expect(try jsonStringObject(encoded.metadataBytes) == ["operatorId": "operator-7"])

        let withoutMetadata = try encodeForKurrent(events: events, metadata: nil as CustomMetadata?)

        #expect(withoutMetadata.metadataBytes == nil)
        #expect(withoutMetadata.events.map(\.customMetadata) == [nil, nil])
        #expect(withoutMetadata.events.map(\.id) == events.map(\.id))
    }
}
