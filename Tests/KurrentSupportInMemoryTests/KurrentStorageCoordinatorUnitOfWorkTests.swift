import Testing
import Foundation
import KurrentDB
import DDDCore
import EventSourcing
import KurrentSupport
import KurrentSupportInMemory
import Synchronization

// `KurrentStorageCoordinator` inside `withUnitOfWork`: appends are staged in the scope's
// backend and committed when the block ends, reads merge the staged events after the
// server's, and purge is refused. Two aggregate types (`Quoting`, `Billing`) with their own
// stream naming, repositories over coordinators, and one `InMemoryEventStoreClient` per
// test unless a test needs two.

// MARK: - Events and aggregates

private struct AuditMetadata: EventMetadata, Equatable {
    let operatorId: String
}

private struct QuoteOpened: DomainEvent {
    typealias Metadata = AuditMetadata
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
    var metadata: AuditMetadata? = nil
    var line: String
}

private struct QuoteLineAdded: DomainEvent {
    typealias Metadata = AuditMetadata
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
    var metadata: AuditMetadata? = nil
    var line: String
}

/// An event `QuotingEventMapper` does not map, so reads leave it out.
private struct QuoteNoted: DomainEvent {
    typealias Metadata = AuditMetadata
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
    var metadata: AuditMetadata? = nil
    var note: String
}

private struct InvoiceIssued: DomainEvent {
    typealias Metadata = AuditMetadata
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
    var metadata: AuditMetadata? = nil
    var amount: Int
}

private final class Quoting: AggregateRoot {
    struct QuotingDeleted: DeletedEvent {
        typealias Metadata = AuditMetadata
        var id: UUID
        var occurred: Date
        var aggregateRootId: String
        var metadata: AuditMetadata? = nil

        init(id: UUID, aggregateRootId: String, occurred: Date) {
            self.id = id
            self.aggregateRootId = aggregateRootId
            self.occurred = occurred
        }
    }
    typealias DeletedEventType = QuotingDeleted

    let id: String
    private(set) var lines: [String] = []
    var metadata: AggregateRootMetadata = .init()

    init(id: String, line: String) throws {
        self.id = id
        try apply(event: QuoteOpened(aggregateRootId: id, line: line))
    }

    required init?(events: [any DomainEvent]) throws {
        guard let opened = events.first as? QuoteOpened else { return nil }
        self.id = opened.aggregateRootId
        try apply(events: events)
    }

    func addLine(_ line: String) throws {
        try apply(event: QuoteLineAdded(aggregateRootId: id, line: line))
    }

    func addNote(_ note: String) throws {
        try apply(event: QuoteNoted(aggregateRootId: id, note: note))
    }

    func when(happened event: some DomainEvent) throws {
        switch event {
        case let opened as QuoteOpened: lines = [opened.line]
        case let added as QuoteLineAdded: lines.append(added.line)
        case is QuotingDeleted: metadata.delete()
        default: break
        }
    }
}

private final class Billing: AggregateRoot {
    struct BillingDeleted: DeletedEvent {
        typealias Metadata = AuditMetadata
        var id: UUID
        var occurred: Date
        var aggregateRootId: String
        var metadata: AuditMetadata? = nil

        init(id: UUID, aggregateRootId: String, occurred: Date) {
            self.id = id
            self.aggregateRootId = aggregateRootId
            self.occurred = occurred
        }
    }
    typealias DeletedEventType = BillingDeleted

    let id: String
    private(set) var amount = 0
    var metadata: AggregateRootMetadata = .init()

    init(id: String, amount: Int) throws {
        self.id = id
        try apply(event: InvoiceIssued(aggregateRootId: id, amount: amount))
    }

    required init?(events: [any DomainEvent]) throws {
        guard let issued = events.first as? InvoiceIssued else { return nil }
        self.id = issued.aggregateRootId
        try apply(events: events)
    }

    func when(happened event: some DomainEvent) throws {
        switch event {
        case let issued as InvoiceIssued: amount = issued.amount
        case is BillingDeleted: metadata.delete()
        default: break
        }
    }
}

// MARK: - Stream naming, mappers, repositories

private enum QuotingStream: EventStreamNaming {
    static var categoryRule: StreamCategoryRule { .custom("Quoting") }
    static var category: String { "Quoting" }
}

private enum BillingStream: EventStreamNaming {
    static var categoryRule: StreamCategoryRule { .custom("Billing") }
    static var category: String { "Billing" }
}

/// Puts quotes in `Order-<id>`, the same streams `BillingAsOrder` uses.
private enum QuotingAsOrder: EventStreamNaming {
    static var categoryRule: StreamCategoryRule { .custom("Order") }
    static var category: String { "Order" }
}

/// Puts invoices in `Order-<id>`, the same streams `QuotingAsOrder` uses.
private enum BillingAsOrder: EventStreamNaming {
    static var categoryRule: StreamCategoryRule { .custom("Order") }
    static var category: String { "Order" }
}

/// Decodes `record` the way generated mappers do: the payload, then `event.metadata` from
/// `customMetadata` when there is any.
private func decodeEvent<Event: DomainEvent>(_ type: Event.Type, from record: any RecordedEventLike) throws -> Event? {
    guard var event = try record.decode(to: Event.self) else { return nil }
    if !record.customMetadata.isEmpty {
        event.metadata = try? JSONDecoder().decode(Event.Metadata.self, from: record.customMetadata)
    }
    return event
}

private struct QuotingEventMapper: EventTypeMapper {
    func mapping(eventData: any RecordedEventLike) throws -> (any DomainEvent)? {
        switch eventData.eventType {
        case "QuoteOpened": return try decodeEvent(QuoteOpened.self, from: eventData)
        case "QuoteLineAdded": return try decodeEvent(QuoteLineAdded.self, from: eventData)
        default: return nil
        }
    }
}

private struct BillingEventMapper: EventTypeMapper {
    func mapping(eventData: any RecordedEventLike) throws -> (any DomainEvent)? {
        switch eventData.eventType {
        case "InvoiceIssued": return try decodeEvent(InvoiceIssued.self, from: eventData)
        default: return nil
        }
    }
}

/// Maps like `QuotingEventMapper` and records the stream name, id and revision of every
/// record it is handed.
private final class RecordingQuotingMapper: EventTypeMapper {
    struct Seen: Equatable, Sendable {
        let streamName: String
        let id: UUID
        let revision: UInt64
    }

    private let records = Mutex<[Seen]>([])

    /// The records handed to `mapping(eventData:)`, in order.
    var seen: [Seen] { records.withLock { $0 } }

    func mapping(eventData: any RecordedEventLike) throws -> (any DomainEvent)? {
        records.withLock {
            $0.append(Seen(streamName: eventData.streamName, id: eventData.id, revision: eventData.revision))
        }
        return try QuotingEventMapper().mapping(eventData: eventData)
    }
}

private struct QuotingRepository<Store: EventStore>: EventSourcingRepository {
    typealias AggregateRootType = Quoting
    let store: Store
}

private struct BillingRepository<Store: EventStore>: EventSourcingRepository {
    typealias AggregateRootType = Billing
    let store: Store
}

private typealias QuotingCoordinator = KurrentStorageCoordinator<QuotingStream, AuditMetadata>
private typealias BillingCoordinator = KurrentStorageCoordinator<BillingStream, AuditMetadata>

private func quotingRepository(_ client: any EventStoreClient) -> QuotingRepository<QuotingCoordinator> {
    QuotingRepository(store: QuotingCoordinator(client: client, eventMapper: QuotingEventMapper()))
}

private func billingRepository(_ client: any EventStoreClient) -> BillingRepository<BillingCoordinator> {
    BillingRepository(store: BillingCoordinator(client: client, eventMapper: BillingEventMapper()))
}

/// Metadata that encodes to a JSON string, not an object: AppendRecords cannot carry it.
private enum Channel: String, EventMetadata {
    case web
}

/// Builds the quote inside the calling task, so the aggregate never crosses a task boundary.
private func saveNewQuote(id: String, to repository: QuotingRepository<QuotingCoordinator>) async throws {
    try await repository.save(aggregateRoot: try Quoting(id: id, line: "desk"))
}

/// Builds the invoice inside the calling task, so the aggregate never crosses a task boundary.
private func saveNewInvoice(id: String, to repository: BillingRepository<BillingCoordinator>) async throws {
    try await repository.save(aggregateRoot: try Billing(id: id, amount: 100))
}

/// Forwards every requirement to an `InMemoryEventStoreClient` except `appendAtomically`,
/// so it relies on the deprecated default, like a conformer written before 1.5.
private struct LegacyOnlyClient: EventStoreClient {
    let wrapped: InMemoryEventStoreClient

    var identity: ObjectIdentifier { wrapped.identity }

    func append(events: [EventData], toStream name: String, category: String, expectedRevision: StreamRevision) async throws -> UInt64? {
        try await wrapped.append(events: events, toStream: name, category: category, expectedRevision: expectedRevision)
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

private enum BodyFailure: Error {
    case thrown
}

/// Counts how often a hook ran.
private final class RunCount: Sendable {
    private let count = Mutex(0)

    var value: Int { count.withLock { $0 } }

    func increment() {
        count.withLock { $0 += 1 }
    }
}

// MARK: - Helpers

private let quoteStream = "Quoting-q-1"
private let billStream = "Billing-b-1"

/// The warning a read logs when the server has no `stream` and nothing is staged for it.
private func streamNotFoundWarning(_ stream: String) -> LogRecorder.Entry {
    .init(level: .warning, message: "Skip an error happened, stream not found: \(stream)")
}

private func storedRecords(_ client: InMemoryEventStoreClient, _ stream: String) async throws -> [any RecordedEventLike] {
    try await client.readStream(name: stream, from: .start, resolveLinks: true)
}

private func storedRevisions(_ client: InMemoryEventStoreClient, _ stream: String) async throws -> [UInt64] {
    try await storedRecords(client, stream).map(\.revision)
}

/// Each stored record's `customMetadata`, decoded as `AuditMetadata`.
private func storedMetadata(_ client: InMemoryEventStoreClient, _ stream: String) async throws -> [AuditMetadata] {
    try await storedRecords(client, stream).map { try JSONDecoder().decode(AuditMetadata.self, from: $0.customMetadata) }
}

private func expectNotWritten(_ client: InMemoryEventStoreClient, _ stream: String, sourceLocation: SourceLocation = #_sourceLocation) async {
    await #expect(throws: EventStoreClientError.streamNotFound, sourceLocation: sourceLocation) {
        _ = try await client.readStream(name: stream, from: .start, resolveLinks: true)
    }
}

/// The error `body` threw, or nil when it returned.
private func thrownError(_ body: () async throws -> Void) async -> (any Error)? {
    do {
        try await body()
        return nil
    } catch {
        return error
    }
}

private extension DDDError {
    var operation: String? { userInfos["operation"] as? String }
    var reason: String? { userInfos["reason"] as? String }
}

/// Checks that `error` is `DDDError.operationNotAllow` for `operation`, and for `reason` when
/// one is given, and returns it.
@discardableResult
private func expectOperationNotAllow(
    _ error: (any Error)?,
    operation: String,
    reason: String? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) -> DDDError? {
    let refused = error as? DDDError
    #expect(refused?.code == .aggregateOperationNotAllowed, "got \(String(describing: error))", sourceLocation: sourceLocation)
    #expect(refused?.operation == operation, sourceLocation: sourceLocation)
    if let reason {
        #expect(refused?.reason == reason, sourceLocation: sourceLocation)
    }
    return refused
}

/// Checks that `error` is what `withUnitOfWork` throws for a failed scope, and returns the
/// cause it carries.
private func failedScopeCause(_ error: (any Error)?, sourceLocation: SourceLocation = #_sourceLocation) -> (any Error)? {
    let refused = expectOperationNotAllow(error, operation: "commit", reason: "unit of work failed", sourceLocation: sourceLocation)
    return refused?.userInfos["cause"] as? any Error
}

// MARK: - Tests

@Suite("KurrentStorageCoordinator inside withUnitOfWork")
struct KurrentStorageCoordinatorUnitOfWorkTests {

    // MARK: commit

    @Test("two repositories on one client commit together when the block ends; the client gets nothing before")
    func twoRepositoriesCommitTogether() async throws {
        let store = InMemoryEventStoreClient()
        let client = CountingClient(wrapping: store)
        let quotes = quotingRepository(client)
        let bills = billingRepository(client)
        let quote = try Quoting(id: "q-1", line: "desk")
        let bill = try Billing(id: "b-1", amount: 100)

        try await withUnitOfWork { _ in
            try await quotes.save(aggregateRoot: quote)
            try await bills.save(aggregateRoot: bill)
            #expect(client.appendCount == 0)
            #expect(client.appendAtomicallyCount == 0)
            await expectNotWritten(store, quoteStream)
            await expectNotWritten(store, billStream)
        }

        #expect(client.appendAtomicallyCount == 1)
        #expect(client.appendCount == 0)
        #expect(try await storedRevisions(store, quoteStream) == [0])
        #expect(try await storedRevisions(store, billStream) == [0])
        #expect(quote.version == 0)
        #expect(bill.version == 0)
        #expect(quote.events.isEmpty)
        #expect(bill.events.isEmpty)
    }

    @Test("a scope that writes one stream commits through the single-stream append")
    func singleStreamScopeUsesV1Append() async throws {
        let store = InMemoryEventStoreClient()
        let client = CountingClient(wrapping: store)
        let quotes = quotingRepository(client)

        try await withUnitOfWork { _ in
            try await quotes.save(aggregateRoot: try Quoting(id: "q-1", line: "desk"))
        }

        #expect(client.appendCount == 1)
        #expect(client.appendAtomicallyCount == 0)
        #expect(try await storedRevisions(store, quoteStream) == [0])
    }

    @Test("the commit returns revisions other than predicted: only logged, so the block returns normally and an onCommitted hook runs")
    func revisionMismatchIsLoggedAndHooksStillRun() async throws {
        let store = InMemoryEventStoreClient()
        let client = CountingClient(wrapping: store, revisionOffset: 10)
        let quotes = quotingRepository(client)
        let bills = billingRepository(client)
        let hookRuns = RunCount()

        let output = try await withUnitOfWork { work in
            try await saveNewQuote(id: "q-1", to: quotes)
            try await saveNewInvoice(id: "b-1", to: bills)
            try work.onCommitted { hookRuns.increment() }
            return "returned"
        }

        #expect(output == "returned")
        #expect(hookRuns.value == 1)
        #expect(client.appendAtomicallyStreams == [[quoteStream, billStream]])
        #expect(try await storedRevisions(store, quoteStream) == [0])
        #expect(try await storedRevisions(store, billStream) == [0])
    }

    // MARK: reads inside a scope

    @Test("a find after a save in the same scope sees the staged events; a second save joins the same batch")
    func secondUsecaseSeesFirstUsecasesEvents() async throws {
        let store = InMemoryEventStoreClient()
        let client = CountingClient(wrapping: store)
        let quotes = quotingRepository(client)

        try await withUnitOfWork { _ in
            let quote = try Quoting(id: "q-1", line: "desk")
            try quote.addLine("chair")
            try quote.addLine("lamp")
            try await quotes.save(aggregateRoot: quote)
            #expect(quote.version == 2)

            let found = try #require(try await quotes.find(byId: "q-1"))
            #expect(found.lines == ["desk", "chair", "lamp"])
            #expect(found.version == 2)
            try found.addLine("rug")
            try await quotes.save(aggregateRoot: found)
            #expect(found.version == 3)
        }

        #expect(client.appendCount == 1)
        #expect(client.appendAtomicallyCount == 0)
        #expect(try await storedRevisions(store, quoteStream) == [0, 1, 2, 3])
        let committed = try #require(try await quotes.find(byId: "q-1"))
        #expect(committed.lines == ["desk", "chair", "lamp", "rug"])
        #expect(committed.version == 3)
    }

    @Test("find inside a scope puts the staged events after the server's: version is the server tail plus the staged count")
    func findMergesStagedOntoExistingStream() async throws {
        let store = InMemoryEventStoreClient()
        let quotes = quotingRepository(store)
        let quote = try Quoting(id: "q-1", line: "desk")
        try quote.addLine("chair")
        try await quotes.save(aggregateRoot: quote)
        #expect(quote.version == 1)

        try await withUnitOfWork { _ in
            let found = try #require(try await quotes.find(byId: "q-1"))
            try found.addLine("lamp")
            try await quotes.save(aggregateRoot: found)
            #expect(found.version == 2)

            let merged = try #require(try await quotes.find(byId: "q-1"))
            #expect(merged.version == 2)
            #expect(merged.lines == ["desk", "chair", "lamp"])
            let fetched = try #require(try await quotes.store.fetchEvents(byId: "q-1"))
            #expect(fetched.events.count == 3)
            #expect(fetched.latestRevision == 2)
        }

        #expect(try await storedRevisions(store, quoteStream) == [0, 1, 2])
    }

    @Test("find inside a scope reports the last staged revision even when the mapper leaves that event out, so the next save expects the staged tail")
    func findReportsLastStagedRevisionWhenMapperSkipsIt() async throws {
        let store = InMemoryEventStoreClient()
        let quotes = quotingRepository(store)

        try await withUnitOfWork { _ in
            let quote = try Quoting(id: "q-1", line: "desk")
            try quote.addNote("call back")
            try await quotes.save(aggregateRoot: quote)
            #expect(quote.version == 1)

            let found = try #require(try await quotes.find(byId: "q-1"))
            #expect(found.version == 1)
            try found.addLine("chair")
            try await quotes.save(aggregateRoot: found)
            #expect(found.version == 2)
        }

        #expect(try await storedRevisions(store, quoteStream) == [0, 1, 2])
    }

    @Test("fetchEvents(byId:afterRevision:) inside a scope numbers the staged events on from the server's and filters them too")
    func fetchAfterRevisionIncludesStagedEvents() async throws {
        let store = InMemoryEventStoreClient()
        let quotes = quotingRepository(store)
        let quote = try Quoting(id: "q-1", line: "desk")
        try quote.addLine("chair")
        try await quotes.save(aggregateRoot: quote)
        let serverIds = try await storedRecords(store, quoteStream).map(\.id)

        try await withUnitOfWork { _ in
            let found = try #require(try await quotes.find(byId: "q-1"))
            try found.addLine("lamp")
            try found.addLine("rug")
            let stagedIds = found.events.map { $0.id }
            try await quotes.save(aggregateRoot: found)

            // The staged events are revisions 2 and 3.
            let afterServerTail = try #require(try await quotes.store.fetchEvents(byId: "q-1", afterRevision: 1))
            #expect(afterServerTail.events.map { $0.id } == stagedIds)
            #expect(afterServerTail.latestRevision == 3)

            let afterFirstStaged = try #require(try await quotes.store.fetchEvents(byId: "q-1", afterRevision: 2))
            #expect(afterFirstStaged.events.map { $0.id } == [stagedIds[1]])
            #expect(afterFirstStaged.latestRevision == 3)

            let afterFirst = try #require(try await quotes.store.fetchEvents(byId: "q-1", afterRevision: 0))
            #expect(afterFirst.events.map { $0.id } == [serverIds[1]] + stagedIds)
            #expect(afterFirst.latestRevision == 3)

            let atStagedTail = try #require(try await quotes.store.fetchEvents(byId: "q-1", afterRevision: 3))
            #expect(atStagedTail.events.isEmpty)
            #expect(atStagedTail.latestRevision == 3)

            // A stream with staged events only, revisions 0–2; the mapper leaves out the last,
            // and latestRevision is still its revision.
            let fresh = try Quoting(id: "q-2", line: "desk")
            try fresh.addLine("chair")
            try fresh.addNote("call back")
            let freshIds = fresh.events.map { $0.id }
            try await quotes.save(aggregateRoot: fresh)
            let afterFreshFirst = try #require(try await quotes.store.fetchEvents(byId: "q-2", afterRevision: 0))
            #expect(afterFreshFirst.events.map { $0.id } == [freshIds[1]])
            #expect(afterFreshFirst.latestRevision == 2)
        }
    }

    @Test("the mapper gets each staged event as a record carrying the stream name, the event's id and its predicted revision")
    func stagedRecordsCarryStreamNameIdAndRevision() async throws {
        let store = InMemoryEventStoreClient()
        let mapper = RecordingQuotingMapper()
        let quotes = QuotingRepository(store: QuotingCoordinator(client: store, eventMapper: mapper))

        try await withUnitOfWork { _ in
            let quote = try Quoting(id: "q-1", line: "desk")
            try quote.addLine("chair")
            let stagedIds = quote.events.map { $0.id }
            try await quotes.save(aggregateRoot: quote)

            _ = try #require(try await quotes.store.fetchEvents(byId: "q-1"))
            #expect(mapper.seen == [
                .init(streamName: quoteStream, id: stagedIds[0], revision: 0),
                .init(streamName: quoteStream, id: stagedIds[1], revision: 1),
            ])
        }
    }

    // MARK: reads leave the scope as they found it

    @Test("a find through one client, then a save through another client only: the scope commits through the second")
    func readThroughOtherClientThenWriteThroughOneClientCommits() async throws {
        let quoteStore = InMemoryEventStoreClient()
        let billStore = InMemoryEventStoreClient()
        try await quotingRepository(quoteStore).save(aggregateRoot: try Quoting(id: "q-1", line: "desk"))
        let quoteClient = CountingClient(wrapping: quoteStore)
        let billClient = CountingClient(wrapping: billStore)
        let quotes = quotingRepository(quoteClient)
        let bills = billingRepository(billClient)

        try await withUnitOfWork { work in
            let found = try #require(try await quotes.find(byId: "q-1"))
            #expect(found.lines == ["desk"])
            try await saveNewInvoice(id: "b-1", to: bills)
            #expect(!work.isFailed)
        }

        #expect(try await storedRevisions(billStore, billStream) == [0])
        #expect(billClient.appendCount == 1)
        #expect(quoteClient.appendCount == 0)
        #expect(quoteClient.appendAtomicallyCount == 0)
        #expect(try await storedRevisions(quoteStore, quoteStream) == [0])
    }

    @Test("a find through another client than the scope's backend reads the server and leaves the scope intact")
    func findThroughOtherClientInsideScopeDoesNotFailTheScope() async throws {
        let quoteStore = InMemoryEventStoreClient()
        let billStore = InMemoryEventStoreClient()
        try await quotingRepository(quoteStore).save(aggregateRoot: try Quoting(id: "q-1", line: "desk"))
        let quoteClient = CountingClient(wrapping: quoteStore)
        let billClient = CountingClient(wrapping: billStore)
        let quotes = quotingRepository(quoteClient)
        let bills = billingRepository(billClient)

        try await withUnitOfWork { work in
            // The save binds the scope's backend to the bills' client.
            try await saveNewInvoice(id: "b-1", to: bills)
            let found = try #require(try await quotes.find(byId: "q-1"))
            #expect(found.lines == ["desk"])
            #expect(found.version == 0)
            let afterFirst = try #require(try await quotes.store.fetchEvents(byId: "q-1", afterRevision: 0))
            #expect(afterFirst.events.isEmpty)
            #expect(afterFirst.latestRevision == 0)
            #expect(!work.isFailed)
        }

        #expect(try await storedRevisions(billStore, billStream) == [0])
        #expect(billClient.appendCount == 1)
        #expect(quoteClient.appendCount == 0)
        #expect(quoteClient.appendAtomicallyCount == 0)
    }

    @Test("a find through another client never sees what the scope staged for the same stream name on its own client")
    func findThroughOtherClientIgnoresStagedEventsOfSameStreamName() async throws {
        let first = InMemoryEventStoreClient()
        let second = InMemoryEventStoreClient()
        try await quotingRepository(first).save(aggregateRoot: try Quoting(id: "q-1", line: "chair"))
        let onFirst = quotingRepository(first)
        let onSecond = quotingRepository(second)

        try await withUnitOfWork { work in
            // Stages Quoting-q-1 on the second client's backend.
            try await saveNewQuote(id: "q-1", to: onSecond)
            let fromFirst = try #require(try await onFirst.find(byId: "q-1"))
            #expect(fromFirst.lines == ["chair"])
            #expect(fromFirst.version == 0)
            let fromSecond = try #require(try await onSecond.find(byId: "q-1"))
            #expect(fromSecond.lines == ["desk"])
            #expect(fromSecond.version == 0)
            #expect(!work.isFailed)
        }

        #expect(try await storedRevisions(first, quoteStream) == [0])
        #expect(try await storedRevisions(second, quoteStream) == [0])
    }

    @Test("a scope that only reads creates no backend, and the client gets no write")
    func findWithoutAnySaveCreatesNoBackend() async throws {
        let store = InMemoryEventStoreClient()
        try await quotingRepository(store).save(aggregateRoot: try Quoting(id: "q-1", line: "desk"))
        let client = CountingClient(wrapping: store)
        let recorder = LogRecorder()
        let quotes = QuotingRepository(
            store: QuotingCoordinator(client: client, eventMapper: QuotingEventMapper(), logger: recorder.logger)
        )

        try await withUnitOfWork { work in
            let found = try #require(try await quotes.find(byId: "q-1"))
            #expect(found.lines == ["desk"])
            #expect(try await quotes.find(byId: "q-2") == nil)
            #expect(recorder.warnings == [streamNotFoundWarning("Quoting-q-2")])
            let afterFirst = try #require(try await quotes.store.fetchEvents(byId: "q-1", afterRevision: 0))
            #expect(afterFirst.events.isEmpty)
            #expect(work.existingBackend(KurrentUnitOfWorkBackend.self, identity: client.identity) == nil)
        }

        #expect(client.appendCount == 0)
        #expect(client.appendAtomicallyCount == 0)
    }

    @Test("a Task started in the block that finds after the scope committed reads the committed state from the server")
    func escapedTaskFindAfterScopeEndReadsTheServer() async throws {
        let store = InMemoryEventStoreClient()
        let client = CountingClient(wrapping: store)
        let quotes = quotingRepository(client)
        let (scopeEnded, endScope) = AsyncStream.makeStream(of: Void.self)
        var escaped: Task<(lines: [String], version: UInt64?)?, any Error>?

        try await withUnitOfWork { _ in
            try await saveNewQuote(id: "q-1", to: quotes)
            escaped = Task {
                for await _ in scopeEnded { break }
                return try await quotes.find(byId: "q-1").map { (lines: $0.lines, version: $0.version) }
            }
        }
        // `withUnitOfWork` has committed q-1; only now does the escaped task find it.
        endScope.yield()
        endScope.finish()
        let task = try #require(escaped)
        let found = try #require(try await task.value)

        #expect(found.lines == ["desk"])
        #expect(found.version == 0)
        #expect(client.appendCount == 1)
        #expect(try await storedRevisions(store, quoteStream) == [0])
    }

    @Test("a read that finds the backend once its commit started reads the server alone: it does not throw, counts no event twice and leaves the scope unfailed")
    func readOfABackendWhoseCommitStartedReadsTheServerAlone() async throws {
        let store = InMemoryEventStoreClient()
        let client = CountingClient(wrapping: store)
        let quotes = quotingRepository(client)

        let error = await thrownError {
            try await withUnitOfWork { work in
                let quote = try Quoting(id: "q-1", line: "desk")
                try quote.addLine("chair")
                try await quotes.save(aggregateRoot: quote)
                // A Task started in the block can find the backend in the still-open scope
                // just before the scope's commit starts on another thread, and only then ask
                // it for the staged events. Starting the commit here, with the scope open,
                // puts the reads below in that position deterministically.
                let backend = try #require(work.existingBackend(KurrentUnitOfWorkBackend.self, identity: client.identity))
                try await backend.commit()

                let found = try #require(try await quotes.find(byId: "q-1"))
                #expect(found.lines == ["desk", "chair"])
                #expect(found.version == 1)
                let afterFirst = try #require(try await quotes.store.fetchEvents(byId: "q-1", afterRevision: 0))
                #expect(afterFirst.events.count == 1)
                #expect(afterFirst.latestRevision == 1)
                #expect(!work.isFailed)
            }
        }

        // Only the scope's own commit fails: it finds its backend already committed.
        expectOperationNotAllow(error, operation: "commit", reason: "unit of work already committed")
        #expect(client.appendCount == 1)
        #expect(try await storedRevisions(store, quoteStream) == [0, 1])
    }

    @Test("a read of a stream that so far exists only as staged events logs no stream-not-found warning; with nothing staged it still does")
    func stagedOnlyStreamLogsNoStreamNotFoundWarning() async throws {
        let store = InMemoryEventStoreClient()
        let recorder = LogRecorder()
        let quotes = QuotingRepository(
            store: QuotingCoordinator(client: store, eventMapper: QuotingEventMapper(), logger: recorder.logger)
        )

        try await withUnitOfWork { _ in
            try await saveNewQuote(id: "q-1", to: quotes)
            let found = try #require(try await quotes.find(byId: "q-1"))
            #expect(found.lines == ["desk"])
            let afterFirst = try #require(try await quotes.store.fetchEvents(byId: "q-1", afterRevision: 0))
            #expect(afterFirst.events.isEmpty)
            #expect(recorder.warnings == [])

            // Nothing is staged for q-2, so the read warns as it does outside a scope.
            #expect(try await quotes.find(byId: "q-2") == nil)
            #expect(recorder.warnings == [streamNotFoundWarning("Quoting-q-2")])
        }

        #expect(try await quotes.find(byId: "q-3") == nil)
        #expect(recorder.warnings == [streamNotFoundWarning("Quoting-q-2"), streamNotFoundWarning("Quoting-q-3")])
    }

    // MARK: commit failures

    @Test("a stream someone else wrote first → commitConflict naming it; neither stream is written; the aggregates are not rolled back")
    func oneStreamAlreadyWrittenConflictsAndWritesNeither() async throws {
        let store = InMemoryEventStoreClient()
        let quotes = quotingRepository(store)
        let bills = billingRepository(store)
        try await quotes.save(aggregateRoot: try Quoting(id: "q-1", line: "elsewhere"))
        let quote = try Quoting(id: "q-1", line: "desk")
        let bill = try Billing(id: "b-1", amount: 100)

        let error = await thrownError {
            try await withUnitOfWork { _ in
                try await quotes.save(aggregateRoot: quote)
                try await bills.save(aggregateRoot: bill)
            }
        }

        let conflict = try #require(error as? DDDError)
        #expect(conflict.code == .commitConflict)
        #expect(conflict.commitConflicts == [DDDError.CommitConflict(id: "q-1", expected: nil, actual: 0)])
        #expect(try await storedRevisions(store, quoteStream) == [0])
        await expectNotWritten(store, billStream)
        // The saves inside the block updated the aggregates; a failed commit does not undo
        // that, which is why the aggregates of a failed block must not be reused.
        #expect(quote.version == 0)
        #expect(quote.events.isEmpty)
        #expect(bill.version == 0)
        #expect(bill.events.isEmpty)
    }

    @Test("both streams written by someone else first → commitConflict lists both")
    func bothStreamsConflictReportTwo() async throws {
        let store = InMemoryEventStoreClient()
        let quotes = quotingRepository(store)
        let bills = billingRepository(store)
        try await quotes.save(aggregateRoot: try Quoting(id: "q-1", line: "elsewhere"))
        try await bills.save(aggregateRoot: try Billing(id: "b-1", amount: 1))

        let error = await thrownError {
            try await withUnitOfWork { _ in
                try await quotes.save(aggregateRoot: try Quoting(id: "q-1", line: "desk"))
                try await bills.save(aggregateRoot: try Billing(id: "b-1", amount: 100))
            }
        }

        let conflict = try #require(error as? DDDError)
        #expect(conflict.code == .commitConflict)
        #expect(conflict.commitConflicts == [
            DDDError.CommitConflict(id: "q-1", expected: nil, actual: 0),
            DDDError.CommitConflict(id: "b-1", expected: nil, actual: 0),
        ])
        #expect(try await storedRevisions(store, quoteStream) == [0])
        #expect(try await storedRevisions(store, billStream) == [0])
    }

    @Test("a save to a purged id inside a scope → streamPurged at the end of the block", arguments: [false, true])
    func purgedStreamThrowsStreamPurged(withSecondStream: Bool) async throws {
        let store = InMemoryEventStoreClient()
        let quotes = quotingRepository(store)
        let bills = billingRepository(store)
        try await quotes.save(aggregateRoot: try Quoting(id: "q-1", line: "desk"))
        try await quotes.purge(byId: "q-1")

        let error = await thrownError {
            try await withUnitOfWork { _ in
                try await quotes.save(aggregateRoot: try Quoting(id: "q-1", line: "again"))
                // The server reports the stream deleted; the staged events are still read.
                let found = try #require(try await quotes.find(byId: "q-1"))
                #expect(found.lines == ["again"])
                #expect(found.version == 0)
                if withSecondStream {
                    try await bills.save(aggregateRoot: try Billing(id: "b-1", amount: 100))
                }
            }
        }

        let purged = try #require(error as? DDDError)
        #expect(purged.code == .streamPurged)
        #expect(purged.userInfos["id"] as? String == "q-1")
        if withSecondStream {
            await expectNotWritten(store, billStream)
        }
    }

    @Test("a client that relies on the deprecated appendAtomically default: two saves stage, the end of the block throws atomicAppendUnsupported")
    func legacyClientTwoStreamsThrowsAtomicAppendUnsupported() async throws {
        let store = InMemoryEventStoreClient()
        let legacy = LegacyOnlyClient(wrapped: store)
        let quotes = quotingRepository(legacy)
        let bills = billingRepository(legacy)

        await #expect(throws: EventStoreClientError.atomicAppendUnsupported) {
            try await withUnitOfWork { _ in
                try await quotes.save(aggregateRoot: try Quoting(id: "q-1", line: "desk"))
                try await bills.save(aggregateRoot: try Billing(id: "b-1", amount: 100))
            }
        }

        await expectNotWritten(store, quoteStream)
        await expectNotWritten(store, billStream)
    }

    @Test("a server without AppendRecords: two streams → withUnitOfWork throws operationNotAllow(commit), nothing is written and no hook runs")
    func unsupportedFeatureBecomesOperationNotAllow() async throws {
        let store = InMemoryEventStoreClient()
        let client = CountingClient(wrapping: store, errorToThrow: appendRecordsUnsupported)
        let quotes = quotingRepository(client)
        let bills = billingRepository(client)
        let hookRuns = RunCount()

        let error = await thrownError {
            try await withUnitOfWork { work in
                try await saveNewQuote(id: "q-1", to: quotes)
                try await saveNewInvoice(id: "b-1", to: bills)
                try work.onCommitted { hookRuns.increment() }
            }
        }

        expectOperationNotAllow(error, operation: "commit", reason: "server does not support AppendRecords (KurrentDB 26.1+)")
        #expect(client.appendAtomicallyCount == 1)
        #expect(client.appendCount == 0)
        #expect(hookRuns.value == 0)
        await expectNotWritten(store, quoteStream)
        await expectNotWritten(store, billStream)
    }

    @Test("a body that throws after saving writes nothing; the aggregates keep what the saves did")
    func bodyThrowWritesNothing() async throws {
        let store = InMemoryEventStoreClient()
        let client = CountingClient(wrapping: store)
        let quotes = quotingRepository(client)
        let bills = billingRepository(client)
        let quote = try Quoting(id: "q-1", line: "desk")
        let bill = try Billing(id: "b-1", amount: 100)

        let error = await thrownError {
            try await withUnitOfWork { _ in
                try await quotes.save(aggregateRoot: quote)
                try await bills.save(aggregateRoot: bill)
                throw BodyFailure.thrown
            }
        }

        #expect(error as? BodyFailure == .thrown)
        #expect(client.appendCount == 0)
        #expect(client.appendAtomicallyCount == 0)
        await expectNotWritten(store, quoteStream)
        await expectNotWritten(store, billStream)
        #expect(quote.version == 0)
        #expect(quote.events.isEmpty)
        #expect(bill.version == 0)
        #expect(bill.events.isEmpty)
    }

    // MARK: consecutive scopes

    @Test("consecutive scopes through the same coordinators each stage into a backend of their own: after a failed scope and after a committed one, a scope commits exactly its own events")
    func consecutiveScopesEachCommitTheirOwnEvents() async throws {
        let store = InMemoryEventStoreClient()
        let client = CountingClient(wrapping: store)
        let quotes = quotingRepository(client)
        let bills = billingRepository(client)

        // Block 1 stages q-1 and then fails, so its backend is discarded without a commit.
        let error = await thrownError {
            try await withUnitOfWork { _ in
                try await quotes.save(aggregateRoot: try Quoting(id: "q-1", line: "abandoned"))
                throw BodyFailure.thrown
            }
        }
        #expect(error as? BodyFailure == .thrown)
        #expect(client.appendCount == 0)
        #expect(client.appendAtomicallyCount == 0)
        await expectNotWritten(store, quoteStream)

        // Block 2, through the same coordinators, stages q-1 and b-1 afresh and commits them.
        let quote = try Quoting(id: "q-1", line: "desk")
        let bill = try Billing(id: "b-1", amount: 100)
        let quoteIds = quote.events.map { $0.id }
        let billIds = bill.events.map { $0.id }
        try await withUnitOfWork { _ in
            try await quotes.save(aggregateRoot: quote)
            try await bills.save(aggregateRoot: bill)
        }

        #expect(client.appendAtomicallyCount == 1)
        #expect(client.appendAtomicallyStreams == [[quoteStream, billStream]])
        #expect(client.appendCount == 0)
        let quoteRecords = try await storedRecords(store, quoteStream)
        #expect(quoteRecords.map(\.revision) == [0])
        #expect(quoteRecords.map(\.id) == quoteIds)
        let billRecords = try await storedRecords(store, billStream)
        #expect(billRecords.map(\.revision) == [0])
        #expect(billRecords.map(\.id) == billIds)
        #expect(quote.version == 0)
        #expect(bill.version == 0)

        // Block 3, after a committed scope, reads block 2's commit and commits on top of it.
        try await withUnitOfWork { _ in
            let found = try #require(try await quotes.find(byId: "q-1"))
            #expect(found.lines == ["desk"])
            #expect(found.version == 0)
            try found.addLine("chair")
            try await quotes.save(aggregateRoot: found)
            try await saveNewInvoice(id: "b-2", to: bills)
        }

        #expect(client.appendAtomicallyStreams == [[quoteStream, billStream], [quoteStream, "Billing-b-2"]])
        #expect(client.appendCount == 0)
        #expect(try await storedRevisions(store, quoteStream) == [0, 1])
        #expect(try await storedRevisions(store, billStream) == [0])
        #expect(try await storedRevisions(store, "Billing-b-2") == [0])
        let committed = try #require(try await quotes.find(byId: "q-1"))
        #expect(committed.lines == ["desk", "chair"])
    }

    // MARK: refused inside a scope

    @Test("purge inside a scope → operationNotAllow; the stream is left as it was")
    func purgeInsideScopeThrows() async throws {
        let store = InMemoryEventStoreClient()
        let quotes = quotingRepository(store)
        try await quotes.save(aggregateRoot: try Quoting(id: "q-1", line: "desk"))

        let error = await thrownError {
            try await withUnitOfWork { _ in
                try await quotes.purge(byId: "q-1")
            }
        }

        expectOperationNotAllow(error, operation: "purge", reason: "not allowed inside a unit of work")
        #expect(try await storedRevisions(store, quoteStream) == [0])
    }

    @Test("coordinators on two InMemoryEventStoreClient instances cannot write in one scope")
    func differentClientInstancesCannotShareAScope() async throws {
        let quoteStore = InMemoryEventStoreClient()
        let billStore = InMemoryEventStoreClient()
        let quotes = quotingRepository(quoteStore)
        let bills = billingRepository(billStore)

        let error = await thrownError {
            try await withUnitOfWork { _ in
                try await quotes.save(aggregateRoot: try Quoting(id: "q-1", line: "desk"))
                try await bills.save(aggregateRoot: try Billing(id: "b-1", amount: 100))
            }
        }

        expectOperationNotAllow(error, operation: "backend", reason: "a unit of work commits through exactly one backend")
        await expectNotWritten(quoteStore, quoteStream)
        await expectNotWritten(billStore, billStream)
    }

    @Test("coordinators whose clients wrap the same InMemoryEventStoreClient share one backend and one commit")
    func sameClientInstanceSharesABackend() async throws {
        let store = InMemoryEventStoreClient()
        let quoteClient = CountingClient(wrapping: store)
        let billClient = CountingClient(wrapping: store)
        let quotes = quotingRepository(quoteClient)
        let bills = billingRepository(billClient)

        try await withUnitOfWork { _ in
            try await quotes.save(aggregateRoot: try Quoting(id: "q-1", line: "desk"))
            try await bills.save(aggregateRoot: try Billing(id: "b-1", amount: 100))
        }

        #expect(quoteClient.appendAtomicallyCount + billClient.appendAtomicallyCount == 1)
        #expect(quoteClient.appendCount + billClient.appendCount == 0)
        #expect(try await storedRevisions(store, quoteStream) == [0])
        #expect(try await storedRevisions(store, billStream) == [0])
    }

    @Test("two aggregate types whose namings give the same stream: the second save conflicts and fails the scope")
    func sameStreamFromTwoCoordinatorsConflicts() async throws {
        let store = InMemoryEventStoreClient()
        let quotes = QuotingRepository(
            store: KurrentStorageCoordinator<QuotingAsOrder, AuditMetadata>(client: store, eventMapper: QuotingEventMapper())
        )
        let bills = BillingRepository(
            store: KurrentStorageCoordinator<BillingAsOrder, AuditMetadata>(client: store, eventMapper: BillingEventMapper())
        )

        let error = await thrownError {
            try await withUnitOfWork { work in
                try await quotes.save(aggregateRoot: try Quoting(id: "1", line: "desk"))
                let saveError = await thrownError {
                    try await bills.save(aggregateRoot: try Billing(id: "1", amount: 100))
                }
                let conflict = saveError as? DDDError
                #expect(conflict?.code == .commitConflict)
                #expect(conflict?.commitConflicts == [DDDError.CommitConflict(id: "1", expected: nil, actual: 0)])
                #expect(work.isFailed)
            }
        }

        let cause = failedScopeCause(error) as? DDDError
        #expect(cause?.code == .commitConflict)
        await expectNotWritten(store, "Order-1")
    }

    // MARK: metadata

    @Test("each save's ambient metadata travels with its own events; a find inside the scope fills event.metadata")
    func metadataPerSaveTravelsWithItsEvents() async throws {
        let store = InMemoryEventStoreClient()
        let quotes = quotingRepository(store)
        let bills = billingRepository(store)
        let alice = AuditMetadata(operatorId: "alice")
        let bob = AuditMetadata(operatorId: "bob")

        try await withUnitOfWork { _ in
            try await EventMetadataContext<AuditMetadata>.withValue(alice) {
                try await quotes.save(aggregateRoot: try Quoting(id: "q-1", line: "desk"))
            }
            try await EventMetadataContext<AuditMetadata>.withValue(bob) {
                try await bills.save(aggregateRoot: try Billing(id: "b-1", amount: 100))
            }

            let quoteEvents = try #require(try await quotes.store.fetchEvents(byId: "q-1")).events
            #expect(quoteEvents.map { ($0 as? QuoteOpened)?.metadata } == [alice])
            let billEvents = try #require(try await bills.store.fetchEvents(byId: "b-1")).events
            #expect(billEvents.map { ($0 as? InvoiceIssued)?.metadata } == [bob])
        }

        #expect(try await storedMetadata(store, quoteStream) == [alice])
        #expect(try await storedMetadata(store, billStream) == [bob])
    }

    @Test("no ambient metadata: the staged events carry no metadata bytes, and none are stored")
    func metadataNilStagesNoBytes() async throws {
        let store = InMemoryEventStoreClient()
        let quotes = quotingRepository(store)

        try await withUnitOfWork { work in
            try await quotes.save(aggregateRoot: try Quoting(id: "q-1", line: "desk"))

            let backend = try work.backend(KurrentUnitOfWorkBackend.self, identity: store.identity) {
                Issue.record("the save should have created the backend")
                return KurrentUnitOfWorkBackend(client: store)
            }
            let staged = try #require(try backend.stagedEvents(stream: quoteStream))
            #expect(staged.events.map(\.customMetadata) == [nil])
            let events = try #require(try await quotes.store.fetchEvents(byId: "q-1")).events
            #expect(events.map { ($0 as? QuoteOpened)?.metadata } == [nil])
        }

        #expect(try await storedRecords(store, quoteStream).map(\.customMetadata) == [Data()])
    }

    @Test("metadata AppendRecords cannot carry → operationNotAllow at save inside a scope; outside a scope it is written")
    func uncarriableMetadataInsideScopeThrows() async throws {
        let store = InMemoryEventStoreClient()
        let recorder = LogRecorder()
        let quotes = QuotingRepository(
            store: KurrentStorageCoordinator<QuotingStream, Channel>(
                client: store, eventMapper: QuotingEventMapper(), logger: recorder.logger
            )
        )
        let quote = try Quoting(id: "q-1", line: "desk")

        let error = await thrownError {
            try await withUnitOfWork { _ in
                let saveError = await thrownError {
                    try await EventMetadataContext<Channel>.withValue(.web) {
                        try await quotes.save(aggregateRoot: quote)
                    }
                }
                let refused = expectOperationNotAllow(saveError, operation: "save")
                #expect(refused?.reason?.hasPrefix("Metadata cannot be carried by AppendRecords: ") == true)
                // The check runs before staging, so the refused save staged nothing to read back.
                let readBack = try await quotes.find(byId: "q-1")
                #expect(readBack == nil)
                #expect(recorder.warnings == [streamNotFoundWarning(quoteStream)])
            }
        }

        // The refusal failed the scope, so nothing was committed and the save changed nothing.
        let cause = failedScopeCause(error)
        expectOperationNotAllow(cause, operation: "save")
        await expectNotWritten(store, quoteStream)
        #expect(quote.version == nil)
        #expect(quote.events.count == 1)

        try await EventMetadataContext<Channel>.withValue(.web) {
            try await quotes.save(aggregateRoot: quote)
        }
        #expect(try await storedRecords(store, quoteStream).map(\.customMetadata) == [Data(#""web""#.utf8)])
    }

    // MARK: expected version beyond Int64

    @Test("an expected version beyond Int64.max inside a scope → commitConflict at save, nothing staged", arguments: [UInt64.max, UInt64(Int64.max) + 1])
    func hugeVersionInsideScopeIsCommitConflictWithoutStaging(version: UInt64) async throws {
        let store = InMemoryEventStoreClient()
        let client = CountingClient(wrapping: store)
        let quotes = quotingRepository(client)
        let quote = try Quoting(id: "q-1", line: "desk")
        quote.update(version: version)

        let error = await thrownError {
            try await withUnitOfWork { work in
                let saveError = await thrownError {
                    try await quotes.save(aggregateRoot: quote)
                }
                let conflict = saveError as? DDDError
                #expect(conflict?.code == .commitConflict)
                #expect(conflict?.commitConflicts == [DDDError.CommitConflict(id: "q-1", expected: version, actual: nil)])

                let backend = try work.backend(KurrentUnitOfWorkBackend.self, identity: store.identity) {
                    KurrentUnitOfWorkBackend(client: store)
                }
                #expect(try backend.stagedEvents(stream: quoteStream) == nil)
            }
        }

        let cause = failedScopeCause(error) as? DDDError
        #expect(cause?.code == .commitConflict)
        #expect(client.appendCount == 0)
        #expect(client.appendAtomicallyCount == 0)
    }

    // MARK: tasks and hooks

    @Test("saves from concurrent child tasks stage into the scope's one backend and commit together")
    func concurrentChildTasksStageIntoOneBackend() async throws {
        let store = InMemoryEventStoreClient()
        let client = CountingClient(wrapping: store)
        let quotes = quotingRepository(client)
        let bills = billingRepository(client)

        try await withUnitOfWork { _ in
            async let quoted: Void = saveNewQuote(id: "q-1", to: quotes)
            async let invoiced: Void = saveNewInvoice(id: "b-1", to: bills)
            try await quoted
            try await invoiced
        }

        #expect(client.appendAtomicallyCount == 1)
        #expect(client.appendCount == 0)
        #expect(try await storedRevisions(store, quoteStream) == [0])
        #expect(try await storedRevisions(store, billStream) == [0])
    }

    @Test("a Task started in the block that saves after the block ended → operationNotAllow, nothing written")
    func escapedTaskAfterScopeEndThrowsAndWritesNothing() async throws {
        let store = InMemoryEventStoreClient()
        let client = CountingClient(wrapping: store)
        let quotes = quotingRepository(client)
        let (scopeEnded, endScope) = AsyncStream.makeStream(of: Void.self)
        var escaped: Task<(any Error)?, Never>?

        let workId = try await withUnitOfWork { work in
            escaped = Task {
                for await _ in scopeEnded { break }
                return await thrownError {
                    try await quotes.save(aggregateRoot: try Quoting(id: "q-1", line: "late"))
                }
            }
            return work.id
        }
        // `withUnitOfWork` has returned; only now does the escaped task save.
        endScope.yield()
        endScope.finish()
        let task = try #require(escaped)
        let error = await task.value

        expectOperationNotAllow(error, operation: "backend", reason: "unit of work \(workId) already ended")
        #expect(client.appendCount == 0)
        #expect(client.appendAtomicallyCount == 0)
        await expectNotWritten(store, quoteStream)
    }

    @Test("a save inside an onCommitted hook writes straight to the client after the atomic commit")
    func saveInsideHookWritesDirectly() async throws {
        let store = InMemoryEventStoreClient()
        let client = CountingClient(wrapping: store)
        let quotes = quotingRepository(client)
        let bills = billingRepository(client)

        try await withUnitOfWork { work in
            try await quotes.save(aggregateRoot: try Quoting(id: "q-1", line: "desk"))
            try await bills.save(aggregateRoot: try Billing(id: "b-1", amount: 100))
            try work.onCommitted {
                // The block's commit has landed before the hook runs.
                #expect(try await storedRevisions(store, quoteStream) == [0])
                try await quotes.save(aggregateRoot: try Quoting(id: "q-2", line: "late"))
            }
        }

        #expect(try await storedRevisions(store, "Quoting-q-2") == [0])
        #expect(client.appendAtomicallyStreams == [[quoteStream, billStream]])
        #expect(client.appendCount == 1)
    }

    // MARK: outside a scope

    @Test("outside a scope a save writes at once and purge tombstones the stream")
    func outsideScopeBehaviourUnchanged() async throws {
        let store = InMemoryEventStoreClient()
        let client = CountingClient(wrapping: store)
        let quotes = quotingRepository(client)
        let quote = try Quoting(id: "q-1", line: "desk")

        try await quotes.save(aggregateRoot: quote)

        #expect(client.appendCount == 1)
        #expect(client.appendAtomicallyCount == 0)
        #expect(try await storedRevisions(store, quoteStream) == [0])
        #expect(quote.version == 0)

        try await quotes.purge(byId: "q-1")

        await #expect(throws: KurrentError.resourceDeleted(resource: quoteStream)) {
            _ = try await store.readStream(name: quoteStream, from: .start, resolveLinks: true)
        }
    }
}
