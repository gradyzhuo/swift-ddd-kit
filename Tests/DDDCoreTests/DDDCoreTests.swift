@testable import DDDCore
@testable import EventSourcing
@testable import KurrentSupport

import EventStoreDB
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

    init(id: String){
        self.id = id
        
        let event = TestAggregateRootCreated(aggregateRootId: id)
        try? self.apply(event: event)
    }

    required convenience init?(first firstEvent: TestAggregateRootCreated, other events: [any DDDCore.DomainEvent]) throws {
        self.init(id: firstEvent.aggregateRootId)
        try self.apply(events: events)
    }

    func when(happened event: some DDDCore.DomainEvent) throws {
        
    }

    func markAsDelete() throws {
        let deletedEvent = DeletedEventType(aggregateRootId: self.id, aggregateRoot2Id: "aggregate2Id")
        try apply(event: deletedEvent)
    }
    
}


struct Mapper: EventTypeMapper {
    func mapping(eventData: EventStoreDB.RecordedEvent) throws -> (any DDDCore.DomainEvent)? {
        return switch eventData.eventType {
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
        self.coordinator = .init(client: client, eventMapper: Mapper())
    }
}

final class DDDCoreTests: XCTestCase {

    
    override func setUp() async throws {
        do{
            let client = try EventStoreDBClient(settings: .localhost())
            try await client.deleteStream(to: .init(name: TestAggregateRoot.getStreamName(id: "idForTesting"))) { options in
                options.revision(expected: .streamExists)
            }
        }catch {
            print("stream not found.")
        }
        
    }
    
    func testRepositorySave() async throws {
        let testId = "idForTesting"
        let aggregateRoot = TestAggregateRoot(id: testId)
        let repository = try TestRepository(client: .init(settings: .localhost()))
        
        try await repository.save(aggregateRoot: aggregateRoot)

        let finded = try await repository.find(byId: testId)
        XCTAssertNotNil(finded)
        
    }
    
    
    func testAggregateRootDeleted() async throws {
        let testId = "idForTesting"
        let aggregateRoot = TestAggregateRoot(id: testId)
        let repository = try TestRepository(client: .init(settings: .localhost()))
        
        try await repository.save(aggregateRoot: aggregateRoot)
        
        try await repository.delete(byId: testId)
        
        let finded = try await repository.find(byId: testId)
        XCTAssertNil(finded)
        
    }
    
    
    func testAggregateRootDeletedShowForcly() async throws {
        let testId = "idForTesting"
        let aggregateRoot = TestAggregateRoot(id: testId)
        let repository = try TestRepository(client: .init(settings: .localhost()))
        
        try await repository.save(aggregateRoot: aggregateRoot)
        
        try await repository.delete(byId: testId)
        
        let finded = try await repository.find(byId: testId, forcly: true)
        XCTAssertNotNil(finded)
        XCTAssertEqual(finded?.isDeleted, true)
    }
}
