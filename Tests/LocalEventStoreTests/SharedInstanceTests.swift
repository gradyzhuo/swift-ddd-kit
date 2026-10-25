import Foundation
import Testing
@testable import DDDCore
@testable import EventSourcing
import LocalEventStore

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

private struct WidgetRenamed: DomainEvent {
    typealias Metadata = TestMetadata
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
    var metadata: TestMetadata? = nil
    var name: String
}

private final class Widget: AggregateRoot {
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

    func rename(to name: String) throws {
        try apply(event: WidgetRenamed(aggregateRootId: id, name: name))
    }

    func when(happened event: some DomainEvent) throws {
        switch event {
        case let e as WidgetCreated: name = e.name
        case let e as WidgetRenamed: name = e.name
        case is WidgetDeleted: metadata.delete()
        default: break
        }
    }
}

private struct WidgetMapper: EventTypeMapper {
    func mapping(eventData: any RecordedEventLike) throws -> (any DomainEvent)? {
        switch eventData.eventType {
        case "WidgetCreated": return try eventData.decode(to: WidgetCreated.self)
        case "WidgetRenamed": return try eventData.decode(to: WidgetRenamed.self)
        default: return nil
        }
    }
}

private typealias WidgetStore = PersistentEventStore<Widget, TestMetadata>

private final class WidgetRepository: EventSourcingRepository {
    typealias AggregateRootType = Widget
    typealias Store = WidgetStore

    let store: WidgetStore

    init(store: WidgetStore) {
        self.store = store
    }
}

private struct WidgetInput: CQRSProjectorInput {
    let id: String
}

private struct WidgetView: ReadModel {
    let id: String
    var name: String
    var renames: Int
}

private struct WidgetProjector: EventSourcingProjector {
    typealias Input = WidgetInput
    typealias ReadModelType = WidgetView
    typealias Store = WidgetStore

    let store: WidgetStore

    func buildReadModel(input: WidgetInput) throws -> WidgetView? {
        WidgetView(id: input.id, name: "", renames: 0)
    }

    func apply(readModel: inout WidgetView, events: [any DomainEvent]) throws {
        for event in events {
            switch event {
            case let e as WidgetCreated:
                readModel.name = e.name
            case let e as WidgetRenamed:
                readModel.name = e.name
                readModel.renames += 1
            default:
                break
            }
        }
    }
}

@Suite("PersistentEventStore shared by repository and projector")
struct SharedInstanceTests {

    @Test("the projector reads what the repository saved through the same instance")
    func projectorReadsRepositoryWrites() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WidgetStore.open(directory: directory, eventMapper: WidgetMapper())
        let repository = WidgetRepository(store: store)
        let projector = WidgetProjector(store: store)

        try await repository.save(aggregateRoot: try Widget(id: "w-1", name: "alpha"))
        let found = try #require(try await repository.find(byId: "w-1"))
        #expect(found.version == 0)
        try found.rename(to: "beta")
        try await repository.save(aggregateRoot: found)

        let output = try #require(try await projector.execute(input: WidgetInput(id: "w-1")))
        #expect(output.readModel.name == "beta")
        #expect(output.readModel.renames == 1)
        await store.close()
    }
}
