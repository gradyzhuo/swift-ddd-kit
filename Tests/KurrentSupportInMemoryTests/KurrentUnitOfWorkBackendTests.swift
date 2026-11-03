import Testing
import Foundation
import KurrentDB
import DDDCore
import EventSourcing
import KurrentSupport
import KurrentSupportInMemory

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

// MARK: - Event encoding fixtures

private struct Placed: DomainEvent {
    typealias Metadata = CustomMetadata
    var id: UUID = .init()
    var occurred: Date = Date(timeIntervalSince1970: 1_700_000_000)
    var aggregateRootId: String
    var metadata: CustomMetadata? = nil
    var amount: Int
}

private struct NoMapper: EventTypeMapper {
    func mapping(eventData: any RecordedEventLike) throws -> (any DomainEvent)? { nil }
}

private enum Naming: EventStreamNaming {
    static var categoryRule: StreamCategoryRule { .custom("Order") }
    static var category: String { "Order" }
}

/// A payload decoded as plain JSON, so two payloads compare field by field.
private enum JSONValue: Decodable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }
}

/// `customMetadata` parsed by `JSONSerialization`; `nil` for no bytes.
private func jsonObject(_ data: Data) throws -> NSDictionary? {
    guard !data.isEmpty else { return nil }
    return try JSONSerialization.jsonObject(with: data) as? NSDictionary
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
        await expectNotWritten(client, "Order-u")
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

    @Test("returned revisions that differ from the prediction are logged, not thrown", arguments: [1, 2])
    func revisionMismatchIsLoggedNotThrown(streamCount: Int) async throws {
        let store = InMemoryEventStoreClient()
        let backend = KurrentUnitOfWorkBackend(client: CountingClient(wrapping: store, revisionOffset: 10))
        let streams = ["a", "b"].prefix(streamCount)
        for id in streams {
            try stage(backend, id, .noStream, samples("\(id)1"))
        }

        try await backend.commit()

        for id in streams {
            #expect(try await storedRevisions(store, "Order-\(id)") == [0])
        }
    }

    // MARK: after commit

    @Test("once committed, stage, stagedEvents and commit throw operationNotAllow")
    func stageAfterCommitThrows() async throws {
        let client = InMemoryEventStoreClient()
        let backend = KurrentUnitOfWorkBackend(client: client)
        try stage(backend, "a", .noStream, samples("a1"))
        try await backend.commit()

        let staging = await captureOperationNotAllow("stage") { try stage(backend, "b", .noStream, samples("b1")) }
        #expect((staging?.userInfos["reason"] as? String)?.contains("already committed") == true)
        let reading = await captureOperationNotAllow("stagedEvents") { _ = try backend.stagedEvents(stream: "Order-a") }
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
        _ = await captureOperationNotAllow("stagedEvents") { _ = try backend.stagedEvents(stream: "Order-a") }
    }

    // MARK: encodeForKurrent

    @Test("encodeForKurrent + client.append stores what KurrentStorageCoordinator.append stores")
    func encodeForKurrentMatchesCoordinatorOutput() async throws {
        let client = InMemoryEventStoreClient()
        let coordinator = KurrentStorageCoordinator<Naming, CustomMetadata>(client: client, eventMapper: NoMapper())
        let events = [Placed(aggregateRootId: "1", amount: 3), Placed(aggregateRootId: "1", amount: 5)]
        let metadata = CustomMetadata(operatorId: "operator-7")

        _ = try await coordinator.append(events: events, byId: "1", version: nil, metadata: metadata)
        let encoded = try encodeForKurrent(events: events, metadata: metadata)
        _ = try await client.append(events: encoded.events, toStream: "Order-direct", category: "Order", expectedRevision: .noStream)

        let viaCoordinator = try await client.readStream(name: Naming.getStreamName(id: "1"), from: .start, resolveLinks: true)
        let viaEncoder = try await client.readStream(name: "Order-direct", from: .start, resolveLinks: true)
        #expect(viaCoordinator.count == events.count)
        #expect(viaEncoder.count == events.count)
        for (expected, actual) in zip(viaCoordinator, viaEncoder) {
            #expect(actual.eventType == expected.eventType)
            #expect(actual.id == expected.id)
            #expect(try actual.decode(to: JSONValue.self) == expected.decode(to: JSONValue.self))
            let expectedMetadata = try #require(try jsonObject(expected.customMetadata))
            #expect(try jsonObject(actual.customMetadata) == expectedMetadata)
        }
        #expect(encoded.metadataBytes != nil)
        #expect(encoded.events.allSatisfy { $0.customMetadata == encoded.metadataBytes })
    }

    @Test("encodeForKurrent without metadata carries no metadata bytes")
    func encodeForKurrentWithoutMetadataCarriesNoBytes() throws {
        let events = [Placed(aggregateRootId: "1", amount: 3)]

        let encoded = try encodeForKurrent(events: events, metadata: nil as CustomMetadata?)

        #expect(encoded.metadataBytes == nil)
        #expect(encoded.events.map(\.customMetadata) == [nil])
        #expect(encoded.events.map(\.id) == events.map(\.id))
        #expect(encoded.events.map(\.eventType) == ["Placed"])
    }
}
