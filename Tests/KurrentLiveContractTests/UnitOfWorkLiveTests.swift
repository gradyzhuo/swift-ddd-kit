import Testing
import Foundation
import DDDCore
import EventSourcing
import KurrentDB
import KurrentSupport
import Synchronization
import TestUtility

// `withUnitOfWork` against a live KurrentDB (26.1+, AppendRecords), and the seam call it
// commits through, `LiveEventStoreClient.appendAtomically`. Repositories are built as apps
// build them: each over its own `KurrentStorageCoordinator` made with the `KurrentDBClient`
// convenience init, all on one `KurrentDBClient`, so they share the unit of work's backend.
// Every test writes streams of fresh ids, so reruns and tests running in parallel never meet.

// MARK: - Metadata, events and aggregates

/// Ambient metadata of mixed types. Inside a unit of work of more than one stream it travels
/// as AppendRecords properties; a read through the v1 API must decode it back unchanged.
struct SpikeMetadata: EventMetadata, Equatable {
    let s: String
    let i: Int
    let b: Bool
    let d: Date
    let o: String?
    let n: Nested

    struct Nested: Codable, Equatable {
        let k: String
    }
}

private struct LiveQuoteOpened: DomainEvent {
    typealias Metadata = SpikeMetadata
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
    var metadata: SpikeMetadata? = nil
    var line: String
}

private struct LiveQuoteLineAdded: DomainEvent {
    typealias Metadata = SpikeMetadata
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
    var metadata: SpikeMetadata? = nil
    var line: String
}

private struct LiveInvoiceIssued: DomainEvent {
    typealias Metadata = SpikeMetadata
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
    var metadata: SpikeMetadata? = nil
    var amount: Int
}

private final class LiveQuote: AggregateRoot {
    struct Deleted: DeletedEvent {
        typealias Metadata = SpikeMetadata
        var id: UUID
        var occurred: Date
        var aggregateRootId: String
        var metadata: SpikeMetadata? = nil

        init(id: UUID, aggregateRootId: String, occurred: Date) {
            self.id = id
            self.aggregateRootId = aggregateRootId
            self.occurred = occurred
        }
    }
    typealias DeletedEventType = Deleted

    let id: String
    private(set) var lines: [String] = []
    var metadata: AggregateRootMetadata = .init()

    init(id: String, line: String) throws {
        self.id = id
        try apply(event: LiveQuoteOpened(aggregateRootId: id, line: line))
    }

    required init?(events: [any DomainEvent]) throws {
        guard let opened = events.first as? LiveQuoteOpened else { return nil }
        self.id = opened.aggregateRootId
        try apply(events: events)
    }

    func addLine(_ line: String) throws {
        try apply(event: LiveQuoteLineAdded(aggregateRootId: id, line: line))
    }

    func when(happened event: some DomainEvent) throws {
        switch event {
        case let opened as LiveQuoteOpened: lines = [opened.line]
        case let added as LiveQuoteLineAdded: lines.append(added.line)
        case is Deleted: metadata.delete()
        default: break
        }
    }
}

private final class LiveInvoice: AggregateRoot {
    struct Deleted: DeletedEvent {
        typealias Metadata = SpikeMetadata
        var id: UUID
        var occurred: Date
        var aggregateRootId: String
        var metadata: SpikeMetadata? = nil

        init(id: UUID, aggregateRootId: String, occurred: Date) {
            self.id = id
            self.aggregateRootId = aggregateRootId
            self.occurred = occurred
        }
    }
    typealias DeletedEventType = Deleted

    let id: String
    private(set) var amount = 0
    var metadata: AggregateRootMetadata = .init()

    init(id: String, amount: Int) throws {
        self.id = id
        try apply(event: LiveInvoiceIssued(aggregateRootId: id, amount: amount))
    }

    required init?(events: [any DomainEvent]) throws {
        guard let issued = events.first as? LiveInvoiceIssued else { return nil }
        self.id = issued.aggregateRootId
        try apply(events: events)
    }

    func when(happened event: some DomainEvent) throws {
        switch event {
        case let issued as LiveInvoiceIssued: amount = issued.amount
        case is Deleted: metadata.delete()
        default: break
        }
    }
}

// MARK: - Stream naming, mappers, repositories

private enum LiveQuoteStream: EventStreamNaming {
    static var categoryRule: StreamCategoryRule { .custom("UowLiveQuote") }
    static var category: String { "UowLiveQuote" }
}

private enum LiveInvoiceStream: EventStreamNaming {
    static var categoryRule: StreamCategoryRule { .custom("UowLiveInvoice") }
    static var category: String { "UowLiveInvoice" }
}

/// A category of this test run alone, so a persistent subscription on its `$ce-` stream gets
/// only this run's events. No dash in it: KurrentDB takes a stream's category from its name up
/// to the first dash, so a dashed category never receives anything.
private enum RunCategoryStream: EventStreamNaming {
    static let category = "Uow" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    static var categoryRule: StreamCategoryRule { .custom(category) }
}

/// Decodes `record` as the mapper `generate event` emits does: the payload, then
/// `event.metadata` from `customMetadata`, left `nil` when it does not decode.
private func decodeAsGeneratedMapper<Event: DomainEvent>(_ type: Event.Type, from record: any RecordedEventLike) throws -> Event? {
    guard var event = try record.decode(to: Event.self) else { return nil }
    if !record.customMetadata.isEmpty {
        let decoder = JSONDecoder()
        event.metadata = try? decoder.decode(Event.Metadata.self, from: record.customMetadata)
    }
    return event
}

private struct LiveQuoteEventMapper: EventTypeMapper {
    func mapping(eventData: any RecordedEventLike) throws -> (any DomainEvent)? {
        switch eventData.eventType {
        case "LiveQuoteOpened": try decodeAsGeneratedMapper(LiveQuoteOpened.self, from: eventData)
        case "LiveQuoteLineAdded": try decodeAsGeneratedMapper(LiveQuoteLineAdded.self, from: eventData)
        default: nil
        }
    }
}

private struct LiveInvoiceEventMapper: EventTypeMapper {
    func mapping(eventData: any RecordedEventLike) throws -> (any DomainEvent)? {
        switch eventData.eventType {
        case "LiveInvoiceIssued": try decodeAsGeneratedMapper(LiveInvoiceIssued.self, from: eventData)
        default: nil
        }
    }
}

private struct LiveQuoteRepository<Store: EventStore>: EventSourcingRepository {
    typealias AggregateRootType = LiveQuote
    let store: Store
}

private struct LiveInvoiceRepository<Store: EventStore>: EventSourcingRepository {
    typealias AggregateRootType = LiveInvoice
    let store: Store
}

/// A quote repository over a coordinator of its own, made with the `KurrentDBClient`
/// convenience init.
private func quoteRepository<Naming: EventStreamNaming>(
    _ client: KurrentDBClient,
    streams: Naming.Type
) -> LiveQuoteRepository<KurrentStorageCoordinator<Naming, SpikeMetadata>> {
    LiveQuoteRepository(store: KurrentStorageCoordinator(client: client, eventMapper: LiveQuoteEventMapper()))
}

/// An invoice repository over a coordinator of its own, made with the `KurrentDBClient`
/// convenience init.
private func invoiceRepository<Naming: EventStreamNaming>(
    _ client: KurrentDBClient,
    streams: Naming.Type
) -> LiveInvoiceRepository<KurrentStorageCoordinator<Naming, SpikeMetadata>> {
    LiveInvoiceRepository(store: KurrentStorageCoordinator(client: client, eventMapper: LiveInvoiceEventMapper()))
}

// MARK: - Helpers

private func newId() -> String {
    UUID().uuidString
}

/// The stream's records as the server has them, read with the v1 API.
private func storedRecords(_ live: LiveEventStoreClient, _ stream: String) async throws -> [any RecordedEventLike] {
    try await live.readStream(name: stream, from: .start, resolveLinks: true)
}

private func expectNotWritten(_ live: LiveEventStoreClient, _ stream: String, sourceLocation: SourceLocation = #_sourceLocation) async {
    await #expect(throws: EventStoreClientError.streamNotFound, sourceLocation: sourceLocation) {
        _ = try await live.readStream(name: stream, from: .start, resolveLinks: true)
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

/// Counts how often a hook ran.
private final class RunCount: Sendable {
    private let count = Mutex(0)

    var value: Int { count.withLock { $0 } }

    func increment() {
        count.withLock { $0 += 1 }
    }
}

/// The ids of the first `count` events `session` delivers, each acked; `nil` when `timeout`
/// passes, or the session ends, before they all arrive.
private func firstDeliveredIds(
    _ session: any PersistentSubscriptionSession,
    count: Int,
    within timeout: Duration
) async throws -> [UUID]? {
    try await withThrowingTaskGroup(of: [UUID]?.self) { group in
        group.addTask {
            var ids: [UUID] = []
            for try await delivery in session.events {
                try await session.ack([delivery])
                ids.append(delivery.event.id)
                if ids.count == count { return ids }
            }
            return nil
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        let first = try await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

// MARK: - withUnitOfWork

@Suite("withUnitOfWork on a live KurrentDB")
struct UnitOfWorkLiveTests {

    @Test("two repositories over one KurrentDBClient commit together when the block ends: nothing on the server before, both streams at revision 0 after")
    func twoRepositoriesLandAtomically() async throws {
        try await KurrentDBClient.withPooledIntegrationTestClient { client in
            let live = LiveEventStoreClient(client: client)
            let quotes = quoteRepository(client, streams: LiveQuoteStream.self)
            let invoices = invoiceRepository(client, streams: LiveInvoiceStream.self)
            let quote = try LiveQuote(id: newId(), line: "desk")
            let invoice = try LiveInvoice(id: newId(), amount: 100)
            let quoteEventIds = quote.events.map { $0.id }
            let invoiceEventIds = invoice.events.map { $0.id }
            let quoteStream = LiveQuoteStream.getStreamName(id: quote.id)
            let invoiceStream = LiveInvoiceStream.getStreamName(id: invoice.id)

            try await withUnitOfWork { _ in
                try await quotes.save(aggregateRoot: quote)
                try await invoices.save(aggregateRoot: invoice)
                await expectNotWritten(live, quoteStream)
                await expectNotWritten(live, invoiceStream)
            }

            let storedQuote = try await storedRecords(live, quoteStream)
            #expect(storedQuote.map(\.id) == quoteEventIds)
            #expect(storedQuote.map(\.revision) == [0])
            let storedInvoice = try await storedRecords(live, invoiceStream)
            #expect(storedInvoice.map(\.id) == invoiceEventIds)
            #expect(storedInvoice.map(\.revision) == [0])
            #expect(quote.version == 0)
            #expect(invoice.version == 0)
        }
    }

    @Test("both streams written by someone else first → commitConflict lists both in save order; nothing new is written")
    func conflictListsEveryStream() async throws {
        try await KurrentDBClient.withPooledIntegrationTestClient { client in
            let live = LiveEventStoreClient(client: client)
            let quotes = quoteRepository(client, streams: LiveQuoteStream.self)
            let invoices = invoiceRepository(client, streams: LiveInvoiceStream.self)
            let quoteId = newId()
            let invoiceId = newId()
            let earlierQuote = try LiveQuote(id: quoteId, line: "elsewhere")
            let earlierInvoice = try LiveInvoice(id: invoiceId, amount: 1)
            let earlierQuoteIds = earlierQuote.events.map { $0.id }
            let earlierInvoiceIds = earlierInvoice.events.map { $0.id }
            try await quotes.save(aggregateRoot: earlierQuote)
            try await invoices.save(aggregateRoot: earlierInvoice)

            let error = await thrownError {
                try await withUnitOfWork { _ in
                    try await quotes.save(aggregateRoot: try LiveQuote(id: quoteId, line: "desk"))
                    try await invoices.save(aggregateRoot: try LiveInvoice(id: invoiceId, amount: 100))
                }
            }

            let conflict = try #require(error as? DDDError, "got \(String(describing: error))")
            #expect(conflict.code == .commitConflict)
            #expect(conflict.commitConflicts == [
                DDDError.CommitConflict(id: quoteId, expected: nil, actual: 0),
                DDDError.CommitConflict(id: invoiceId, expected: nil, actual: 0),
            ])
            #expect(try await storedRecords(live, LiveQuoteStream.getStreamName(id: quoteId)).map(\.id) == earlierQuoteIds)
            #expect(try await storedRecords(live, LiveInvoiceStream.getStreamName(id: invoiceId)).map(\.id) == earlierInvoiceIds)
        }
    }

    @Test("a save to a purged id next to another stream → streamPurged naming the purged id; the other stream is not written")
    func tombstonedStreamIsStreamPurged() async throws {
        try await KurrentDBClient.withPooledIntegrationTestClient { client in
            let live = LiveEventStoreClient(client: client)
            let quotes = quoteRepository(client, streams: LiveQuoteStream.self)
            let invoices = invoiceRepository(client, streams: LiveInvoiceStream.self)
            let quoteId = newId()
            let invoiceId = newId()
            try await quotes.save(aggregateRoot: try LiveQuote(id: quoteId, line: "desk"))
            try await quotes.purge(byId: quoteId)

            let error = await thrownError {
                try await withUnitOfWork { _ in
                    try await quotes.save(aggregateRoot: try LiveQuote(id: quoteId, line: "again"))
                    try await invoices.save(aggregateRoot: try LiveInvoice(id: invoiceId, amount: 100))
                }
            }

            let purged = try #require(error as? DDDError, "got \(String(describing: error))")
            #expect(purged.code == .streamPurged)
            #expect(purged.userInfos["id"] as? String == quoteId)
            await expectNotWritten(live, LiveInvoiceStream.getStreamName(id: invoiceId))
        }
    }

    @Test("a purged id and a conflicting stream in one commit → streamPurged, not commitConflict, wherever the purged one is in the batch; nothing new is written")
    func tombstonedNextToConflictIsStreamPurged() async throws {
        try await KurrentDBClient.withPooledIntegrationTestClient { client in
            let live = LiveEventStoreClient(client: client)
            let quotes = quoteRepository(client, streams: LiveQuoteStream.self)
            let invoices = invoiceRepository(client, streams: LiveInvoiceStream.self)
            let quoteId = newId()
            let invoiceId = newId()
            try await quotes.save(aggregateRoot: try LiveQuote(id: quoteId, line: "desk"))
            try await quotes.purge(byId: quoteId)
            let earlierInvoice = try LiveInvoice(id: invoiceId, amount: 1)
            let earlierInvoiceIds = earlierInvoice.events.map { $0.id }
            try await invoices.save(aggregateRoot: earlierInvoice)

            let error = await thrownError {
                try await withUnitOfWork { _ in
                    // The conflicting stream first, so the purged one is not first in the batch.
                    try await invoices.save(aggregateRoot: try LiveInvoice(id: invoiceId, amount: 100))
                    try await quotes.save(aggregateRoot: try LiveQuote(id: quoteId, line: "again"))
                }
            }

            let purged = try #require(error as? DDDError, "got \(String(describing: error))")
            #expect(purged.code == .streamPurged)
            #expect(purged.userInfos["id"] as? String == quoteId)
            #expect(try await storedRecords(live, LiveInvoiceStream.getStreamName(id: invoiceId)).map(\.id) == earlierInvoiceIds)
        }
    }

    @Test("events a unit of work wrote through AppendRecords read back through the coordinator and a generated-style mapper with their eventType, payload and mixed-type metadata")
    func readBackThroughMapperMatchesWrite() async throws {
        try await KurrentDBClient.withPooledIntegrationTestClient { client in
            let quotes = quoteRepository(client, streams: LiveQuoteStream.self)
            let invoices = invoiceRepository(client, streams: LiveInvoiceStream.self)
            let metadata = SpikeMetadata(
                s: "x",
                i: 7,
                b: true,
                d: Date(timeIntervalSince1970: 1_700_000_000),
                o: nil,
                n: .init(k: "v")
            )
            let quote = try LiveQuote(id: newId(), line: "desk")
            try quote.addLine("chair")
            let invoice = try LiveInvoice(id: newId(), amount: 100)
            let quoteEventIds = quote.events.map { $0.id }
            let invoiceEventIds = invoice.events.map { $0.id }

            try await withUnitOfWork { _ in
                try await EventMetadataContext<SpikeMetadata>.withValue(metadata) {
                    try await quotes.save(aggregateRoot: quote)
                    try await invoices.save(aggregateRoot: invoice)
                }
            }

            // Only the decoded struct is compared: the server adds "$schema.name" and
            // "$schema.format" keys to the stored metadata bytes.
            let quoteEvents = try #require(try await quotes.store.fetchEvents(byId: quote.id)).events
            #expect(quoteEvents.map { $0.id } == quoteEventIds)
            #expect(quoteEvents.map { $0.eventType } == ["LiveQuoteOpened", "LiveQuoteLineAdded"])
            let opened = try #require(quoteEvents.first as? LiveQuoteOpened)
            let added = try #require(quoteEvents.last as? LiveQuoteLineAdded)
            #expect(opened.aggregateRootId == quote.id)
            #expect(opened.line == "desk")
            #expect(opened.metadata == metadata)
            #expect(added.aggregateRootId == quote.id)
            #expect(added.line == "chair")
            #expect(added.metadata == metadata)

            let invoiceEvents = try #require(try await invoices.store.fetchEvents(byId: invoice.id)).events
            #expect(invoiceEvents.map { $0.id } == invoiceEventIds)
            #expect(invoiceEvents.map { $0.eventType } == ["LiveInvoiceIssued"])
            let issued = try #require(invoiceEvents.first as? LiveInvoiceIssued)
            #expect(issued.aggregateRootId == invoice.id)
            #expect(issued.amount == 100)
            #expect(issued.metadata == metadata)
        }
    }

    @Test("a stream soft-deleted at revisions 0–2 and created again inside a scope: the block returns normally, the hook runs, and find gives version 3, the old tail + 1")
    func softDeletedStreamRecreatedInScopeCommits() async throws {
        try await KurrentDBClient.withPooledIntegrationTestClient { client in
            let live = LiveEventStoreClient(client: client)
            let quotes = quoteRepository(client, streams: LiveQuoteStream.self)
            let invoices = invoiceRepository(client, streams: LiveInvoiceStream.self)
            let quoteId = newId()
            let original = try LiveQuote(id: quoteId, line: "desk")
            try original.addLine("chair")
            try original.addLine("lamp")
            try await quotes.save(aggregateRoot: original)
            #expect(original.version == 2)
            try await live.deleteStream(name: LiveQuoteStream.getStreamName(id: quoteId), expectedRevision: .at(2))
            let recreated = try LiveQuote(id: quoteId, line: "again")
            let hookRuns = RunCount()

            // The server puts the new event at revision 3, not the predicted 0: the backend
            // logs a warning and the commit stands.
            let output = try await withUnitOfWork { work in
                try await quotes.save(aggregateRoot: recreated)
                try await invoices.save(aggregateRoot: try LiveInvoice(id: newId(), amount: 100))
                try work.onCommitted { hookRuns.increment() }
                return "returned"
            }

            #expect(output == "returned")
            #expect(hookRuns.value == 1)
            // The saved aggregate keeps the predicted version; it must not be reused.
            #expect(recreated.version == 0)
            let found = try #require(try await quotes.find(byId: quoteId))
            #expect(found.version == 3)
            #expect(found.lines == ["again"])
        }
    }

    @Test("a persistent subscription on $ce-<category> receives both events a unit of work wrote to two streams of that category")
    func categorySubscriptionReceivesUnitOfWorkEvents() async throws {
        try await KurrentDBClient.withPooledIntegrationTestClient { client in
            let live = LiveEventStoreClient(client: client)
            let stream = "$ce-\(RunCategoryStream.category)"
            let group = "uow-live-\(UUID().uuidString.prefix(8))"
            try await live.ensurePersistentSubscription(stream: stream, group: group, settings: .init())
            do {
                let session = try await live.subscribePersistent(stream: stream, group: group)
                let quotes = quoteRepository(client, streams: RunCategoryStream.self)
                let invoices = invoiceRepository(client, streams: RunCategoryStream.self)
                let quote = try LiveQuote(id: newId(), line: "desk")
                let invoice = try LiveInvoice(id: newId(), amount: 100)
                let savedIds = (quote.events + invoice.events).map { $0.id }

                try await withUnitOfWork { _ in
                    try await quotes.save(aggregateRoot: quote)
                    try await invoices.save(aggregateRoot: invoice)
                }

                let delivered = try await firstDeliveredIds(session, count: 2, within: .seconds(10))
                #expect(delivered.map(Set.init) == Set(savedIds), "\(stream) did not deliver both events within 10 s")
            } catch {
                try? await live.deletePersistentSubscription(stream: stream, group: group)
                throw error
            }
            try await live.deletePersistentSubscription(stream: stream, group: group)
        }
    }
}

// MARK: - LiveEventStoreClient.appendAtomically

private struct SeamEvent: Codable, Sendable {
    let text: String
}

/// A stream name of its own, in the `UowSeam` category.
private func seamStream() -> String {
    "UowSeam-\(UUID().uuidString)"
}

private func seamEvent(_ text: String) -> EventData {
    EventData(eventType: "SeamEvent", model: SeamEvent(text: text))
}

private func batch(_ stream: String, _ expected: StreamRevision, _ events: [EventData]) -> StreamBatch {
    StreamBatch(stream: stream, category: "UowSeam", expectedRevision: expected, events: events)
}

/// Results come back in no particular order; sort them to compare.
private func sortedByStream(_ results: [StreamBatchResult]) -> [StreamBatchResult] {
    results.sorted { $0.stream < $1.stream }
}

/// A stream that held one event and was then tombstoned.
private func tombstonedStream(_ live: LiveEventStoreClient) async throws -> String {
    let stream = seamStream()
    _ = try await live.append(events: [seamEvent("before")], toStream: stream, category: "UowSeam", expectedRevision: .noStream)
    try await live.tombstoneStream(name: stream)
    return stream
}

// Pins what `appendAtomically` makes of the server's answers (spec §9, KurrentDB 26.1): in a
// consistency violation `actualState` -1 is a missing stream (`current == nil`) and -6 a
// tombstoned one, which wins over revision conflicts in the same request; a resent request
// with the same event ids is idempotent.
@Suite("LiveEventStoreClient.appendAtomically on a live KurrentDB")
struct LiveEventStoreClientAppendAtomicallyTests {

    @Test("an existing stream under .noStream and a missing stream under .at(5) → consistencyViolations with current 0 and nil, in batch order; nothing written")
    func missingStreamUnderAtReportsCurrentNil() async throws {
        try await KurrentDBClient.withPooledIntegrationTestClient { client in
            let live = LiveEventStoreClient(client: client)
            let existing = seamStream()
            let missing = seamStream()
            let earlier = seamEvent("earlier")
            _ = try await live.append(events: [earlier], toStream: existing, category: "UowSeam", expectedRevision: .noStream)

            await #expect(throws: EventStoreClientError.consistencyViolations([
                StreamConflict(stream: existing, expected: .noStream, current: 0),
                StreamConflict(stream: missing, expected: .at(5), current: nil),
            ])) {
                try await live.appendAtomically([
                    batch(existing, .noStream, [seamEvent("e")]),
                    batch(missing, .at(5), [seamEvent("m")]),
                ])
            }

            #expect(try await storedRecords(live, existing).map(\.id) == [earlier.id])
            await expectNotWritten(live, missing)
        }
    }

    @Test("a tombstoned stream → KurrentError.resourceDeleted naming it; the other stream is not written")
    func tombstonedStreamThrowsResourceDeleted() async throws {
        try await KurrentDBClient.withPooledIntegrationTestClient { client in
            let live = LiveEventStoreClient(client: client)
            let tombstoned = try await tombstonedStream(live)
            let fresh = seamStream()

            await #expect(throws: KurrentError.resourceDeleted(resource: tombstoned)) {
                try await live.appendAtomically([
                    batch(tombstoned, .noStream, [seamEvent("t")]),
                    batch(fresh, .noStream, [seamEvent("u")]),
                ])
            }

            await expectNotWritten(live, fresh)
        }
    }

    @Test("a revision conflict and a tombstoned stream in one request → resourceDeleted naming the tombstoned one, not consistencyViolations; nothing written")
    func tombstonedWinsOverConflict() async throws {
        try await KurrentDBClient.withPooledIntegrationTestClient { client in
            let live = LiveEventStoreClient(client: client)
            let tombstoned = try await tombstonedStream(live)
            let conflicting = seamStream()
            let earlier = seamEvent("earlier")
            _ = try await live.append(events: [earlier], toStream: conflicting, category: "UowSeam", expectedRevision: .noStream)

            await #expect(throws: KurrentError.resourceDeleted(resource: tombstoned)) {
                try await live.appendAtomically([
                    batch(conflicting, .noStream, [seamEvent("c")]),
                    batch(tombstoned, .noStream, [seamEvent("t")]),
                ])
            }

            #expect(try await storedRecords(live, conflicting).map(\.id) == [earlier.id])
        }
    }

    @Test("resending the same request with the same event ids under .noStream returns the same revisions and writes nothing twice")
    func resendingTheSameRecordIdsIsIdempotent() async throws {
        try await KurrentDBClient.withPooledIntegrationTestClient { client in
            let live = LiveEventStoreClient(client: client)
            let a = seamStream()
            let b = seamStream()
            let aEvents = [seamEvent("a1"), seamEvent("a2")]
            let bEvents = [seamEvent("b1")]
            let batches = [batch(a, .noStream, aEvents), batch(b, .noStream, bEvents)]

            let first = try await live.appendAtomically(batches)
            let second = try await live.appendAtomically(batches)

            #expect(sortedByStream(first) == sortedByStream([
                StreamBatchResult(stream: a, revision: 1),
                StreamBatchResult(stream: b, revision: 0),
            ]))
            #expect(sortedByStream(second) == sortedByStream(first))
            #expect(try await storedRecords(live, a).map(\.id) == aEvents.map(\.id))
            #expect(try await storedRecords(live, b).map(\.id) == bEvents.map(\.id))
        }
    }
}
