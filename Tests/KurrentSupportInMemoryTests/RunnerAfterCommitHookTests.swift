import Testing
import Foundation
import Synchronization
import KurrentDB
import DDDCore
import EventSourcing
import ReadModelPersistence
import KurrentSupport
import KurrentSupportInMemory

// MARK: - Fixtures

private struct Booked: DomainEvent, Codable, Sendable {
    typealias Metadata = Never
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
    var metadata: Never? = nil
}

private struct Ignored: DomainEvent, Codable, Sendable {
    typealias Metadata = Never
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
    var metadata: Never? = nil
}

private struct HookMapper: EventTypeMapper {
    func mapping(eventData: any RecordedEventLike) throws -> (any DomainEvent)? {
        switch eventData.eventType {
        case "Booked": try eventData.decode(to: Booked.self)
        case "Ignored": try eventData.decode(to: Ignored.self)
        default: nil
        }
    }
}

private struct BookingModel: ReadModel, Codable, Sendable { let id: String }
private struct BookingInput: CQRSProjectorInput, Sendable { let id: String }

private struct BookingProjector: EventSourcingProjector, Sendable {
    typealias Input = BookingInput
    typealias ReadModelType = BookingModel
    typealias Store = KurrentStorageCoordinator<BookingProjector, CustomMetadata>
    static var categoryRule: StreamCategoryRule { .custom("Booking") }
    let store: KurrentStorageCoordinator<BookingProjector, CustomMetadata>
    func apply(readModel: inout BookingModel, events: [any DomainEvent]) throws {}
    func buildReadModel(input: BookingInput) throws -> BookingModel? { BookingModel(id: input.id) }
}

/// Transaction provider that records what happened to each transaction.
private final class RecordingProvider: TransactionProvider, Sendable {
    typealias Transaction = Int
    let outcomes = Mutex<[String]>([])
    func withTransaction<Result: Sendable>(_ body: (Int) async throws -> Result) async throws -> Result {
        do {
            let result = try await body(0)
            outcomes.withLock { $0.append("commit") }
            return result
        } catch {
            outcomes.withLock { $0.append("rollback") }
            throw error
        }
    }
}

/// Tx-bound store over a shared dictionary; `failingIds` throw on save.
private final class SharedRows: Sendable {
    let rows = Mutex<[String: StoredReadModel<BookingModel>]>([:])
    let saves = Mutex<[String]>([])
}

private struct TxStore: TransactionalReadModelStore {
    typealias Model = BookingModel
    typealias Transaction = Int
    let shared: SharedRows
    var failingIds: Set<String> = []

    func fetch(byId id: String, in transaction: Int) async throws -> StoredReadModel<BookingModel>? {
        shared.rows.withLock { $0[id] }
    }
    func save(readModel: BookingModel, revision: UInt64, in transaction: Int) async throws {
        if failingIds.contains(readModel.id) { struct SaveFailed: Error {}; throw SaveFailed() }
        shared.rows.withLock { $0[readModel.id] = StoredReadModel(readModel: readModel, revision: revision) }
        shared.saves.withLock { $0.append(readModel.id) }
    }
}

private final class Recorder: Sendable {
    let commits = Mutex<[KurrentProjection.CommittedProjection]>([])
    var count: Int { commits.withLock { $0.count } }
    var all: [KurrentProjection.CommittedProjection] { commits.withLock { $0 } }
}

private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("condition not met within \(timeout)")
}

private func append(_ event: some DomainEvent, id: String, to coordinator: KurrentStorageCoordinator<BookingProjector, CustomMetadata>) async throws {
    _ = try await coordinator.append(events: [event], byId: id, version: nil, metadata: nil)
}

private struct BookedOnly: EventTypeFilter {
    func handles(eventType: String) -> Bool { eventType == "Booked" }
}
private let bookedOnly = BookedOnly()

// MARK: - TransactionalSubscriptionRunner

@Suite("TransactionalSubscriptionRunner — onCommitted hook")
struct TransactionalAfterCommitHookTests {

    private struct Harness {
        let client = InMemoryEventStoreClient()
        let provider = RecordingProvider()
        let shared = SharedRows()
        let recorder = Recorder()
        var coordinator: KurrentStorageCoordinator<BookingProjector, CustomMetadata> {
            .init(client: client, eventMapper: HookMapper())
        }
        var projector: BookingProjector { BookingProjector(store: coordinator) }
    }

    @Test("Fires after the transaction committed, listing the ids saved in it")
    func firesAfterCommit() async throws {
        let h = Harness()
        try await append(Booked(aggregateRootId: "b-1"), id: "b-1", to: h.coordinator)

        let provider = h.provider
        let recorder = h.recorder
        let outcomesAtHook = Mutex<[String]>([])
        let runner = KurrentProjection.TransactionalSubscriptionRunner(
            client: h.client, transactionProvider: provider, stream: "$ce-Booking", groupName: "g"
        )
        .register(projector: h.projector, storeFactory: { [shared = h.shared] _ in TxStore(shared: shared) }) {
            BookingInput(id: $0.streamName.replacingOccurrences(of: "Booking-", with: ""))
        }
        .onCommitted { committed in
            outcomesAtHook.withLock { $0 = provider.outcomes.withLock { $0 } }
            recorder.commits.withLock { $0.append(committed) }
        }

        let task = Task { try await runner.run() }
        try await waitUntil { recorder.count == 1 }
        task.cancel()

        let committed = try #require(recorder.all.first)
        #expect(committed.eventType == "Booked")
        #expect(committed.streamName == "Booking-b-1")
        #expect(committed.revision == 0)
        #expect(committed.readModelIds == ["b-1"])
        #expect(committed.writtenReadModels == [.init(readModelTypeName: "BookingModel", id: "b-1")])
        #expect(outcomesAtHook.withLock { $0 } == ["commit"])
    }

    @Test("Registrations whose fold had nothing new are not listed")
    func noOpFoldNotListed() async throws {
        let h = Harness()
        try await append(Booked(aggregateRootId: "b-1"), id: "b-1", to: h.coordinator)
        // Row for "b-0" is already at the latest revision of a stream that has one event.
        try await append(Booked(aggregateRootId: "b-0"), id: "b-0", to: h.coordinator)
        h.shared.rows.withLock { $0["b-0"] = StoredReadModel(readModel: BookingModel(id: "b-0"), revision: 0) }

        let recorder = h.recorder
        let runner = KurrentProjection.TransactionalSubscriptionRunner(
            client: h.client, transactionProvider: h.provider, stream: "$ce-Booking", groupName: "g"
        )
        .register(projector: h.projector, storeFactory: { [shared = h.shared] _ in TxStore(shared: shared) }) {
            BookingInput(id: $0.streamName.replacingOccurrences(of: "Booking-", with: ""))
        }
        // Second registration always folds "b-0", which never has anything new.
        .register(projector: h.projector, storeFactory: { [shared = h.shared] _ in TxStore(shared: shared) }) { _ in
            BookingInput(id: "b-0")
        }
        .onCommitted { committed in recorder.commits.withLock { $0.append(committed) } }

        let task = Task { try await runner.run() }
        try await waitUntil { recorder.count == 2 }
        task.cancel()

        #expect(recorder.all.map(\.readModelIds) == [["b-1"], []])
    }

    @Test("Does not fire when the transaction rolled back")
    func notOnRollback() async throws {
        let h = Harness()
        try await append(Booked(aggregateRootId: "bad"), id: "bad", to: h.coordinator)
        try await append(Booked(aggregateRootId: "ok"), id: "ok", to: h.coordinator)

        let recorder = h.recorder
        let runner = KurrentProjection.TransactionalSubscriptionRunner(
            client: h.client, transactionProvider: h.provider, stream: "$ce-Booking", groupName: "g",
            retryPolicy: KurrentProjection.MaxRetriesPolicy(max: 0)
        )
        .register(projector: h.projector, storeFactory: { [shared = h.shared] _ in TxStore(shared: shared, failingIds: ["bad"]) }) {
            BookingInput(id: $0.streamName.replacingOccurrences(of: "Booking-", with: ""))
        }
        .onCommitted { committed in recorder.commits.withLock { $0.append(committed) } }

        let task = Task { try await runner.run() }
        try await waitUntil { recorder.count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        #expect(h.provider.outcomes.withLock { $0 } == ["rollback", "commit"])
        #expect(recorder.all.map(\.readModelIds) == [["ok"]])
    }

    @Test("Does not fire for a filtered-out event or a nil extractInput")
    func notOnFilteredOrNilInput() async throws {
        let h = Harness()
        try await append(Ignored(aggregateRootId: "x"), id: "x", to: h.coordinator)       // filtered
        try await append(Booked(aggregateRootId: "skip"), id: "skip", to: h.coordinator)  // nil input
        try await append(Booked(aggregateRootId: "b-1"), id: "b-1", to: h.coordinator)

        let recorder = h.recorder
        let runner = KurrentProjection.TransactionalSubscriptionRunner(
            client: h.client, transactionProvider: h.provider, stream: "$ce-Booking", groupName: "g"
        )
        .register(projector: h.projector, storeFactory: { [shared = h.shared] _ in TxStore(shared: shared) }, eventFilter: bookedOnly) {
            let id = $0.streamName.replacingOccurrences(of: "Booking-", with: "")
            return id == "skip" ? nil : BookingInput(id: id)
        }
        .onCommitted { committed in recorder.commits.withLock { $0.append(committed) } }

        let task = Task { try await runner.run() }
        try await waitUntil { recorder.count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        #expect(recorder.all.map(\.streamName) == ["Booking-b-1"])
    }

    @Test("A slow hook blocks neither later deliveries nor their commits; hooks still run in order")
    func slowHookDoesNotBlock() async throws {
        let h = Harness()
        try await append(Booked(aggregateRootId: "b-1"), id: "b-1", to: h.coordinator)
        try await append(Booked(aggregateRootId: "b-2"), id: "b-2", to: h.coordinator)

        let recorder = h.recorder
        let runner = KurrentProjection.TransactionalSubscriptionRunner(
            client: h.client, transactionProvider: h.provider, stream: "$ce-Booking", groupName: "g"
        )
        .register(projector: h.projector, storeFactory: { [shared = h.shared] _ in TxStore(shared: shared) }) {
            BookingInput(id: $0.streamName.replacingOccurrences(of: "Booking-", with: ""))
        }
        .onCommitted { committed in
            if committed.readModelIds == ["b-1"] { try? await Task.sleep(for: .milliseconds(300)) }
            recorder.commits.withLock { $0.append(committed) }
        }

        let started = ContinuousClock.now
        let task = Task { try await runner.run() }
        try await waitUntil { h.shared.saves.withLock { $0.count } == 2 }
        #expect(ContinuousClock.now - started < .milliseconds(250))
        #expect(recorder.count == 0)
        try await waitUntil { recorder.count == 2 }
        task.cancel()

        #expect(recorder.all.map(\.readModelIds) == [["b-1"], ["b-2"]])
    }

    @Test("Several hooks all fire")
    func multipleHooks() async throws {
        let h = Harness()
        try await append(Booked(aggregateRootId: "b-1"), id: "b-1", to: h.coordinator)

        let first = Recorder(), second = Recorder()
        let runner = KurrentProjection.TransactionalSubscriptionRunner(
            client: h.client, transactionProvider: h.provider, stream: "$ce-Booking", groupName: "g"
        )
        .register(projector: h.projector, storeFactory: { [shared = h.shared] _ in TxStore(shared: shared) }) {
            BookingInput(id: $0.streamName.replacingOccurrences(of: "Booking-", with: ""))
        }
        .onCommitted { c in first.commits.withLock { $0.append(c) } }
        .onCommitted { c in second.commits.withLock { $0.append(c) } }

        let task = Task { try await runner.run() }
        try await waitUntil { first.count == 1 && second.count == 1 }
        task.cancel()
    }
}

// MARK: - PersistentSubscriptionRunner

@Suite("PersistentSubscriptionRunner — onCommitted hook")
struct PersistentAfterCommitHookTests {

    @Test("Fires after the store saves succeeded, listing the ids saved")
    func firesAfterSave() async throws {
        let client = InMemoryEventStoreClient()
        let coordinator = KurrentStorageCoordinator<BookingProjector, CustomMetadata>(client: client, eventMapper: HookMapper())
        try await append(Booked(aggregateRootId: "b-1"), id: "b-1", to: coordinator)
        let store = InMemoryReadModelStore<BookingModel>()

        let recorder = Recorder()
        let storedAtHook = Mutex<Bool>(false)
        let runner = KurrentProjection.PersistentSubscriptionRunner(client: client, stream: "$ce-Booking", groupName: "g")
            .register(projector: BookingProjector(store: coordinator), store: store) {
                BookingInput(id: $0.streamName.replacingOccurrences(of: "Booking-", with: ""))
            }
            .onCommitted { committed in
                let stored = (try? await store.fetch(byId: "b-1")) != nil
                storedAtHook.withLock { $0 = stored }
                recorder.commits.withLock { $0.append(committed) }
            }

        let task = Task { try await runner.run() }
        try await waitUntil { recorder.count == 1 }
        task.cancel()

        let committed = try #require(recorder.all.first)
        #expect(committed.eventType == "Booked")
        #expect(committed.streamName == "Booking-b-1")
        #expect(committed.readModelIds == ["b-1"])
        #expect(storedAtHook.withLock { $0 })
    }

    @Test("Does not fire when a projector throws, nor for filtered / nil-input events")
    func notOnFailureFilterOrNilInput() async throws {
        let client = InMemoryEventStoreClient()
        let coordinator = KurrentStorageCoordinator<BookingProjector, CustomMetadata>(client: client, eventMapper: HookMapper())
        try await append(Ignored(aggregateRootId: "x"), id: "x", to: coordinator)
        try await append(Booked(aggregateRootId: "skip"), id: "skip", to: coordinator)
        try await append(Booked(aggregateRootId: "bad"), id: "bad", to: coordinator)
        try await append(Booked(aggregateRootId: "ok"), id: "ok", to: coordinator)

        struct Boom: Error {}
        let recorder = Recorder()
        let runner = KurrentProjection.PersistentSubscriptionRunner(
            client: client, stream: "$ce-Booking", groupName: "g",
            retryPolicy: KurrentProjection.MaxRetriesPolicy(max: 0)
        )
        .register(eventFilter: bookedOnly, extractInput: { record -> String? in
            let id = record.streamName.replacingOccurrences(of: "Booking-", with: "")
            return id == "skip" ? nil : id
        }, execute: { id in
            if id == "bad" { throw Boom() }
        })
        .onCommitted { committed in recorder.commits.withLock { $0.append(committed) } }

        let task = Task { try await runner.run() }
        try await waitUntil { recorder.count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        // Closure registrations save nothing the runner can see, so no ids are listed.
        #expect(recorder.all.map(\.streamName) == ["Booking-ok"])
        #expect(recorder.all.map(\.readModelIds) == [[]])
    }

    @Test("A slow hook does not hold up the next delivery")
    func slowHookDoesNotBlock() async throws {
        let client = InMemoryEventStoreClient()
        let coordinator = KurrentStorageCoordinator<BookingProjector, CustomMetadata>(client: client, eventMapper: HookMapper())
        try await append(Booked(aggregateRootId: "b-1"), id: "b-1", to: coordinator)
        try await append(Booked(aggregateRootId: "b-2"), id: "b-2", to: coordinator)

        let handled = Mutex<[String]>([])
        let recorder = Recorder()
        let runner = KurrentProjection.PersistentSubscriptionRunner(client: client, stream: "$ce-Booking", groupName: "g")
            .register(extractInput: { $0.streamName }, execute: { name in handled.withLock { $0.append(name) } })
            .onCommitted { committed in
                if committed.streamName == "Booking-b-1" { try? await Task.sleep(for: .milliseconds(300)) }
                recorder.commits.withLock { $0.append(committed) }
            }

        let started = ContinuousClock.now
        let task = Task { try await runner.run() }
        try await waitUntil { handled.withLock { $0.count } == 2 }
        #expect(ContinuousClock.now - started < .milliseconds(250))
        try await waitUntil { recorder.count == 2 }
        task.cancel()

        #expect(recorder.all.map(\.streamName) == ["Booking-b-1", "Booking-b-2"])
    }
}
