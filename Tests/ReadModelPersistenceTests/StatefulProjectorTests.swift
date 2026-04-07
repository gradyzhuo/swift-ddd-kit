import Testing
import Foundation
@testable import DDDCore
@testable import EventSourcing
@testable import ReadModelPersistence

// MARK: - Test Fixtures

private struct CountIncremented: DomainEvent {
    typealias Metadata = Never
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
    var metadata: Never? = nil
    var value: Int
}

private struct TestReadModel: ReadModel, Sendable {
    typealias ID = String
    let id: String
    var total: Int = 0
    var applyCount: Int = 0
}

private struct TestInput: CQRSProjectorInput {
    let id: String
}

/// Plain EventSourcingProjector — contains only projection logic, no store.
private struct TestProjector: EventSourcingProjector {
    typealias Input = TestInput
    typealias ReadModelType = TestReadModel
    typealias StorageCoordinator = InMemoryStorageCoordinator

    static var categoryRule: StreamCategoryRule { .custom("Test") }

    let coordinator: InMemoryStorageCoordinator

    func buildReadModel(input: TestInput) throws -> TestReadModel? {
        TestReadModel(id: input.id)
    }

    func apply(readModel: inout TestReadModel, events: [any DomainEvent]) throws {
        for event in events {
            if let e = event as? CountIncremented {
                readModel.total += e.value
                readModel.applyCount += 1
            }
        }
    }
}

// MARK: - StatefulEventSourcingProjector Tests

@Suite("StatefulEventSourcingProjector")
struct StatefulProjectorTests {

    @Test("首次 execute 全量重播並快取")
    func firstExecuteFullReplayAndCaches() async throws {
        let coordinator = InMemoryStorageCoordinator()
        let store       = InMemoryReadModelStore<TestReadModel>()
        let stateful    = StatefulEventSourcingProjector(
            projector: TestProjector(coordinator: coordinator),
            store: store
        )

        _ = try await coordinator.append(
            events: [
                CountIncremented(aggregateRootId: "a1", value: 10),
                CountIncremented(aggregateRootId: "a1", value: 20),
            ],
            byId: "a1", version: nil, external: nil
        )

        let result = try await stateful.execute(input: TestInput(id: "a1"))

        #expect(result?.readModel.total == 30)
        #expect(result?.readModel.applyCount == 2)

        let cached = try await store.fetch(byId: "a1")
        #expect(cached != nil)
        #expect(cached?.readModel.total == 30)
        #expect(cached?.revision == 2)
    }

    @Test("增量更新只 apply 新 events")
    func incrementalUpdateAppliesOnlyNewEvents() async throws {
        let coordinator = InMemoryStorageCoordinator()
        let store       = InMemoryReadModelStore<TestReadModel>()
        let stateful    = StatefulEventSourcingProjector(
            projector: TestProjector(coordinator: coordinator),
            store: store
        )

        _ = try await coordinator.append(
            events: [
                CountIncremented(aggregateRootId: "a1", value: 10),
                CountIncremented(aggregateRootId: "a1", value: 20),
            ],
            byId: "a1", version: nil, external: nil
        )

        // First execute — full replay
        _ = try await stateful.execute(input: TestInput(id: "a1"))

        _ = try await coordinator.append(
            events: [CountIncremented(aggregateRootId: "a1", value: 5)],
            byId: "a1", version: 2, external: nil
        )

        // Second execute — incremental
        let result = try await stateful.execute(input: TestInput(id: "a1"))

        #expect(result?.readModel.total == 35)
        #expect(result?.readModel.applyCount == 3)

        let cached = try await store.fetch(byId: "a1")
        #expect(cached?.revision == 3)
    }

    @Test("無新 events 回傳快取不重新 apply")
    func noNewEventsReturnsCachedModel() async throws {
        let coordinator = InMemoryStorageCoordinator()
        let store       = InMemoryReadModelStore<TestReadModel>()
        let stateful    = StatefulEventSourcingProjector(
            projector: TestProjector(coordinator: coordinator),
            store: store
        )

        _ = try await coordinator.append(
            events: [CountIncremented(aggregateRootId: "a1", value: 10)],
            byId: "a1", version: nil, external: nil
        )

        _ = try await stateful.execute(input: TestInput(id: "a1"))

        // Execute again without new events
        let result = try await stateful.execute(input: TestInput(id: "a1"))

        #expect(result?.readModel.total == 10)
        #expect(result?.readModel.applyCount == 1) // Not re-applied
    }

    @Test("不存在的 id 回傳 nil")
    func unknownIdReturnsNil() async throws {
        let coordinator = InMemoryStorageCoordinator()
        let store       = InMemoryReadModelStore<TestReadModel>()
        let stateful    = StatefulEventSourcingProjector(
            projector: TestProjector(coordinator: coordinator),
            store: store
        )

        let result = try await stateful.execute(input: TestInput(id: "ghost"))
        #expect(result == nil)
    }
}

// MARK: - InMemoryReadModelStore Tests

@Suite("InMemoryReadModelStore")
struct InMemoryReadModelStoreTests {

    @Test("save 後 fetch 取得快照")
    func saveAndFetch() async throws {
        let store = InMemoryReadModelStore<TestReadModel>()
        let model = TestReadModel(id: "m1", total: 42)

        try await store.save(readModel: model, revision: 5)
        let stored = try await store.fetch(byId: "m1")

        #expect(stored?.readModel.id == "m1")
        #expect(stored?.readModel.total == 42)
        #expect(stored?.revision == 5)
    }

    @Test("fetch 不存在的 id 回傳 nil")
    func fetchNonExistentReturnsNil() async throws {
        let store = InMemoryReadModelStore<TestReadModel>()
        let result = try await store.fetch(byId: "nothing")
        #expect(result == nil)
    }

    @Test("save 覆寫既有快照")
    func saveOverwritesExisting() async throws {
        let store = InMemoryReadModelStore<TestReadModel>()

        try await store.save(readModel: TestReadModel(id: "m1", total: 10), revision: 1)
        try await store.save(readModel: TestReadModel(id: "m1", total: 20), revision: 3)

        let stored = try await store.fetch(byId: "m1")
        #expect(stored?.readModel.total == 20)
        #expect(stored?.revision == 3)
    }

    @Test("delete 後 fetch 回傳 nil")
    func deleteRemovesSnapshot() async throws {
        let store = InMemoryReadModelStore<TestReadModel>()

        try await store.save(readModel: TestReadModel(id: "m1", total: 10), revision: 1)
        try await store.delete(byId: "m1")

        let result = try await store.fetch(byId: "m1")
        #expect(result == nil)
    }
}

// MARK: - InMemoryStorageCoordinator.fetchEvents(afterRevision:) Tests

@Suite("EventStorageCoordinator.fetchEvents(afterRevision:)")
struct FetchEventsAfterRevisionTests {

    @Test("afterRevision 回傳之後的 events")
    func returnsEventsAfterRevision() async throws {
        let coordinator = InMemoryStorageCoordinator()

        _ = try await coordinator.append(
            events: [
                CountIncremented(aggregateRootId: "a1", value: 1),
                CountIncremented(aggregateRootId: "a1", value: 2),
                CountIncremented(aggregateRootId: "a1", value: 3),
            ],
            byId: "a1", version: nil, external: nil
        )

        let result = try await coordinator.fetchEvents(byId: "a1", afterRevision: 2)

        #expect(result?.events.count == 1)
        #expect((result?.events.first as? CountIncremented)?.value == 3)
        #expect(result?.latestRevision == 3)
    }

    @Test("afterRevision 等於 latestRevision 回傳空 events")
    func returnsEmptyWhenUpToDate() async throws {
        let coordinator = InMemoryStorageCoordinator()

        _ = try await coordinator.append(
            events: [CountIncremented(aggregateRootId: "a1", value: 1)],
            byId: "a1", version: nil, external: nil
        )

        let result = try await coordinator.fetchEvents(byId: "a1", afterRevision: 1)

        #expect(result?.events.isEmpty == true)
        #expect(result?.latestRevision == 1)
    }

    @Test("不存在的 id 回傳 nil")
    func returnsNilForUnknownId() async throws {
        let coordinator = InMemoryStorageCoordinator()
        let result = try await coordinator.fetchEvents(byId: "ghost", afterRevision: 0)
        #expect(result == nil)
    }
}
