// Tests/EventSourcingTests/EventSourcingRepositoryMetadataTests.swift
import Foundation
import Testing
@testable import DDDCore
@testable import EventSourcing

// MARK: - Fixtures

private struct TestMetadata: EventMetadata, Equatable {
    let operatorId: String
}

private struct WidgetCreated: DomainEvent {
    typealias Metadata = TestMetadata
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
    var metadata: TestMetadata? = nil
    var name: String
}

private final class Widget: AggregateRoot, @unchecked Sendable {
    struct WidgetDeleted: DeletedEvent {
        typealias Metadata = TestMetadata
        var id: UUID = .init()
        var occurred: Date = .now
        var aggregateRootId: String
        var metadata: TestMetadata? = nil

        init(id: UUID, aggregateRootId: String, occurred: Date) {
            self.id = id
            self.aggregateRootId = aggregateRootId
            self.occurred = occurred
        }
    }
    typealias DeletedEventType = WidgetDeleted

    let id: String
    private(set) var name: String = ""
    var metadata: AggregateRootMetadata = .init()

    init(id: String, name: String) throws {
        self.id = id
        try apply(event: WidgetCreated(aggregateRootId: id, name: name))
    }

    required init?(events: [any DomainEvent]) throws {
        guard let first = events.first as? WidgetCreated else { return nil }
        self.id = first.aggregateRootId
        try apply(events: events)
    }

    func when(happened event: some DomainEvent) throws {
        switch event {
        case let e as WidgetCreated: name = e.name
        case is WidgetDeleted: metadata.delete()
        default: break
        }
    }
}

private final class WidgetRepository: EventSourcingRepository {
    typealias AggregateRootType = Widget
    typealias Store = InMemoryStorageCoordinator<TestMetadata>

    let store: InMemoryStorageCoordinator<TestMetadata>

    init(store: InMemoryStorageCoordinator<TestMetadata>) {
        self.store = store
    }
}

// MARK: - Tests

@Suite("EventSourcingRepository × EventMetadataContext")
struct EventSourcingRepositoryMetadataTests {

    @Test("save inside withValue propagates metadata to the store")
    func saveWithAmbientMetadata() async throws {
        let store = InMemoryStorageCoordinator<TestMetadata>()
        let repo = WidgetRepository(store: store)
        let widget = try Widget(id: "w-1", name: "alpha")

        try await EventMetadataContext<TestMetadata>.withValue(TestMetadata(operatorId: "u-42")) {
            try await repo.save(aggregateRoot: widget)
        }

        let recorded = await store.recordedMetadata(byId: "w-1")
        #expect(recorded == [TestMetadata(operatorId: "u-42")])
    }

    @Test("save outside withValue records nil metadata (no crash)")
    func saveWithoutAmbient() async throws {
        let store = InMemoryStorageCoordinator<TestMetadata>()
        let repo = WidgetRepository(store: store)
        let widget = try Widget(id: "w-2", name: "beta")

        try await repo.save(aggregateRoot: widget)

        let recorded = await store.recordedMetadata(byId: "w-2")
        #expect(recorded == [TestMetadata?.none])
    }

    @Test("Two saves under different withValue scopes record their respective metadata")
    func saveAcrossScopes() async throws {
        let store = InMemoryStorageCoordinator<TestMetadata>()
        let repo = WidgetRepository(store: store)
        let widget1 = try Widget(id: "w-3", name: "gamma")
        let widget2 = try Widget(id: "w-4", name: "delta")

        try await EventMetadataContext<TestMetadata>.withValue(TestMetadata(operatorId: "alice")) {
            try await repo.save(aggregateRoot: widget1)
        }
        try await EventMetadataContext<TestMetadata>.withValue(TestMetadata(operatorId: "bob")) {
            try await repo.save(aggregateRoot: widget2)
        }

        let recorded1 = await store.recordedMetadata(byId: "w-3")
        let recorded2 = await store.recordedMetadata(byId: "w-4")
        #expect(recorded1 == [TestMetadata(operatorId: "alice")])
        #expect(recorded2 == [TestMetadata(operatorId: "bob")])
    }

    @Test("Multiple events from one save share the same metadata bytes")
    func batchSaveSharesMetadata() async throws {
        let store = InMemoryStorageCoordinator<TestMetadata>()
        let repo = WidgetRepository(store: store)
        let widget = try Widget(id: "w-5", name: "first")
        // Append another event to the same aggregate so save flushes both
        try widget.apply(event: WidgetCreated(aggregateRootId: "w-5", name: "second"))

        try await EventMetadataContext<TestMetadata>.withValue(TestMetadata(operatorId: "charlie")) {
            try await repo.save(aggregateRoot: widget)
        }

        let recorded = await store.recordedMetadata(byId: "w-5")
        #expect(recorded.count == 2)
        #expect(recorded.allSatisfy { $0 == TestMetadata(operatorId: "charlie") })
    }
}
