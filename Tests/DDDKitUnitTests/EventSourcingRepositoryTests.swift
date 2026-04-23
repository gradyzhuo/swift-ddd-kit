import Testing
import Foundation
import Synchronization
@testable import DDDCore
@testable import EventSourcing

// MARK: - Fixtures (reuse Order from AggregateRootTests via shared module)

private struct ItemCreated: DomainEvent {
    typealias Metadata = Never
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
    var metadata: Never? = nil
    var name: String
}

private struct ItemDeleted: DeletedEvent {
    typealias Metadata = Never
    var id: UUID
    var occurred: Date
    var aggregateRootId: String
    var metadata: Never? = nil

    init(id: UUID = .init(), aggregateRootId: String, occurred: Date = .now) {
        self.id = id
        self.aggregateRootId = aggregateRootId
        self.occurred = occurred
    }
}

private final class Item: AggregateRoot {
    typealias DeletedEventType = ItemDeleted

    let id: String
    private(set) var name: String = ""
    var metadata: AggregateRootMetadata = .init()

    init(id: String, name: String) throws {
        self.id = id
        try apply(event: ItemCreated(aggregateRootId: id, name: name))
    }

    required init?(events: [any DomainEvent]) throws {
        guard let first = events.first as? ItemCreated else { return nil }
        self.id = first.aggregateRootId
        try apply(events: events)
    }

    func when(happened event: some DomainEvent) throws {
        switch event {
        case let e as ItemCreated: name = e.name
        case is ItemDeleted:       metadata.delete()
        default: break
        }
    }
}

// MARK: - In-Memory Coordinator

private final class InMemoryCoordinator: EventStorageCoordinator {
    let _store: Mutex<[String: (events: [any DomainEvent], revision: UInt64)]> = .init([:])
    let _appendCallCount: Mutex<Int> = .init(0)
    
    var store: [String: (events: [any DomainEvent], revision: UInt64)]{
        get{
            _store.withLock{ $0 }
        }
        
        set{
            _store.withLock{ $0 = newValue }
        }
    }
    
    var appendCallCount: Int {
        get{
            _appendCallCount.withLock{ $0 }
        }
        set{
            _appendCallCount.withLock{ $0 = newValue }
        }
    }
    
    func fetchEvents(byId id: String) async throws -> (events: [any DomainEvent], latestRevision: UInt64)? {
        guard let entry = store[id] else { return nil }
        return (events: entry.events, latestRevision: entry.revision)
    }

    func append(events: [any DomainEvent], byId id: String, version: UInt64?, external: [String: String]?) async throws -> UInt64? {
        appendCallCount += 1
        let existing = store[id]?.events ?? []
        let newRevision = UInt64(existing.count + events.count)
        store[id] = (events: existing + events, revision: newRevision)
        return newRevision
    }

    func purge(byId id: String) async throws {
        store.removeValue(forKey: id)
    }
}

private final class ItemRepository: EventSourcingRepository {
    typealias AggregateRootType = Item
    typealias StorageCoordinator = InMemoryCoordinator

    let coordinator: InMemoryCoordinator
    init(coordinator: InMemoryCoordinator) { self.coordinator = coordinator }
}

// MARK: - Repository Tests

@Suite("EventSourcingRepository")
struct EventSourcingRepositoryTests {

    @Test("save 後 events 被寫入 coordinator")
    func saveWritesEventsToCoordinator() async throws {
        let coordinator = InMemoryCoordinator()
        let repo = ItemRepository(coordinator: coordinator)
        let item = try Item(id: "item-1", name: "apple")

        try await repo.save(aggregateRoot: item, external: nil)

        #expect(coordinator.store["item-1"] != nil)
        #expect(coordinator.store["item-1"]?.events.count == 1)
    }

    @Test("save 後 metadata.events 被清空")
    func saveClearsUncommittedEvents() async throws {
        let coordinator = InMemoryCoordinator()
        let repo = ItemRepository(coordinator: coordinator)
        let item = try Item(id: "item-1", name: "apple")

        try await repo.save(aggregateRoot: item, external: nil)

        #expect(item.events.isEmpty)
    }

    @Test("save 後 version 更新")
    func saveUpdatesVersion() async throws {
        let coordinator = InMemoryCoordinator()
        let repo = ItemRepository(coordinator: coordinator)
        let item = try Item(id: "item-1", name: "apple")

        #expect(item.version == nil)
        try await repo.save(aggregateRoot: item, external: nil)
        #expect(item.version != nil)
    }

    @Test("find 不存在的 id 回傳 nil")
    func findUnknownIdReturnsNil() async throws {
        let repo = ItemRepository(coordinator: .init())
        let result = try await repo.find(byId: "ghost")
        #expect(result == nil)
    }

    @Test("save 後 find 可重建 aggregate")
    func saveAndFindRebuildsAggregate() async throws {
        let coordinator = InMemoryCoordinator()
        let repo = ItemRepository(coordinator: coordinator)
        let item = try Item(id: "item-1", name: "apple")

        try await repo.save(aggregateRoot: item, external: nil)
        let found = try await repo.find(byId: "item-1")

        #expect(found?.id == "item-1")
        #expect(found?.name == "apple")
    }

    @Test("delete 後 find 預設回傳 nil")
    func deleteHidesAggregate() async throws {
        let coordinator = InMemoryCoordinator()
        let repo = ItemRepository(coordinator: coordinator)
        let item = try Item(id: "item-1", name: "apple")

        try await repo.save(aggregateRoot: item, external: nil)
        try await repo.delete(byId: "item-1", external: nil)

        let found = try await repo.find(byId: "item-1")
        #expect(found == nil)
    }

    // TODO: find(hiddingDeleted: false) 目前在 when(happened: DeletedEvent) 設定
    // metadata.deleted 時會因 markDelete() + apply(deletedEvent) 雙重呼叫而拋錯。
    // 需修正 EventSourcingRepository.find 的還原邏輯後再啟用此 test。

    @Test("purge 後 coordinator 中的資料消失")
    func purgeRemovesFromCoordinator() async throws {
        let coordinator = InMemoryCoordinator()
        let repo = ItemRepository(coordinator: coordinator)
        let item = try Item(id: "item-1", name: "apple")

        try await repo.save(aggregateRoot: item, external: nil)
        try await repo.purge(byId: "item-1")

        #expect(coordinator.store["item-1"] == nil)
    }

    @Test("delete 不存在的 aggregate 拋錯")
    func deleteNonExistentThrows() async throws {
        let repo = ItemRepository(coordinator: .init())
        await #expect(throws: (any Error).self) {
            try await repo.delete(byId: "ghost", external: nil)
        }
    }

    @Test("purge 不存在的 aggregate 拋錯")
    func purgeNonExistentThrows() async throws {
        let repo = ItemRepository(coordinator: .init())
        await #expect(throws: (any Error).self) {
            try await repo.purge(byId: "ghost")
        }
    }
}
