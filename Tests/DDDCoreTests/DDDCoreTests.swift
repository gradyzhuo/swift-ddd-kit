@testable import DDDCore
@testable import KurrentSupport
@testable import EventSourcing


import EventStoreDB
import TestUtility
import XCTest

struct TestAggregateRootCreated: DomainEvent {
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
}

struct TestAggregateRootDeleted: DeletedEvent {
    var id: UUID = .init()

    var occurred: Date = .now

    let aggregateRootId: String
    let aggregateRoot2Id: String

    init(aggregateRootId: String, aggregateRoot2Id: String) {
        self.aggregateRootId = aggregateRootId
        self.aggregateRoot2Id = aggregateRoot2Id
    }
}

class TestAggregateRoot: AggregateRoot {
    typealias CreatedEventType = TestAggregateRootCreated

    typealias DeletedEventType = TestAggregateRootDeleted

    typealias ID = String
    var id: String

    var metadata: DDDCore.AggregateRootMetadata = .init()

    init(id: String) {
        self.id = id

        let event = TestAggregateRootCreated(aggregateRootId: id)
        try? apply(event: event)
    }

    required convenience init?(first firstEvent: TestAggregateRootCreated, other events: [any DDDCore.DomainEvent]) throws {
        self.init(id: firstEvent.aggregateRootId)
        try apply(events: events)
    }

    func when(happened _: some DDDCore.DomainEvent) throws {}

    func markAsDelete() throws {
        let deletedEvent = DeletedEventType(aggregateRootId: id, aggregateRoot2Id: "aggregate2Id")
        try apply(event: deletedEvent)
    }
}

struct Mapper: EventTypeMapper {
    func mapping(eventData: EventStoreDB.RecordedEvent) throws -> (any DDDCore.DomainEvent)? {
        switch eventData.eventType {
        case "TestAggregateRootCreated":
            try eventData.decode(to: TestAggregateRootCreated.self)
        case "TestAggregateRootDeleted":
            try eventData.decode(to: TestAggregateRootDeleted.self)
        default:
            nil
        }
    }
}

class TestRepository: EventSourcingRepository {    
    typealias AggregateRootType = TestAggregateRoot
    typealias StorageCoordinator = KurrentStorageCoordinator<TestAggregateRoot>

    var coordinator: StorageCoordinator

    init(client: EventStoreDBClient) {
        coordinator = .init(client: client, eventMapper: Mapper())
    }
}

class TestProjector: EventSourcingProjector {

    typealias ProjectableType = TestAggregateRoot
    typealias StorageCoordinator = KurrentStorageCoordinator<TestAggregateRoot>

    var coordinator: StorageCoordinator

    init(client: EventStoreDBClient) {
        coordinator = .init(client: client, eventMapper: Mapper())
    }
}

final class DDDCoreTests: XCTestCase {
    var client: EventStoreDBClient?
    override func setUp() async throws {
        self.client = .init(settings: .localhost())
        await client?.clearStreams(projectableType: TestAggregateRoot.self, id: "idForTesting") {
            print("error:", $0)
        }
    }

    func testRepositorySave() async throws {
        let testId = "idForTesting"
        let testUserId = "testUserId"
        let aggregateRoot = TestAggregateRoot(id: testId)
        let repository = TestRepository(client: .init(settings: .localhost()))
        
        try await repository.save(aggregateRoot: aggregateRoot, userId: testUserId)

        let finded = try await repository.find(byId: testId)
        XCTAssertNotNil(finded)
    }

    func testProjectorFind() async throws {
        let testId = "idForTesting"
        let testUserId = "testUserId"
        let aggregateRoot = TestAggregateRoot(id: testId)
        let repository = TestRepository(client: .init(settings: .localhost()))
        try await repository.save(aggregateRoot: aggregateRoot, userId: testUserId)

        let projector = try TestProjector(client: .init(settings: .localhost()))
        let finded = try await projector.find(byId: testId)
        XCTAssertNotNil(finded)
    }
}

