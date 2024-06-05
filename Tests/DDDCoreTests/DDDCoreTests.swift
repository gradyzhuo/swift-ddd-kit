@testable import DDDCore
@testable import EventSourcing

import EventStoreDB
import XCTest


struct TestAggregateRootCreated: DomainEvent {
    var eventType: String = "TestAggregateRootCreated"

    var occurred: Date = .now

    var aggregateId: String

    var eventId: String


}

struct TestAggregateRootDeleted: DeletedEvent {
    

    var eventId: String

    var eventType: String = "TestAggregateRootDeleted"

    var occurred: Date = .now

    var aggregateId: String

    init(eventId: String, aggregateId: String) {
        self.eventId = eventId
        self.aggregateId = aggregateId
    }
    // init() {
    //     self.id = UUID.init().uuidString
    // }

}

class TestAggregateRoot: AggregateRoot {
    typealias CreatedEventType = TestAggregateRootCreated

    typealias DeletedEventType = TestAggregateRootDeleted

    typealias ID = String
    var id: String
    
    var metadata: DDDCore.AggregateRootMetadata = .init()

    init(id: String){
        self.id = id
        
        let event = TestAggregateRootCreated(aggregateId: id, eventId: UUID().uuidString)
        try? self.apply(event: event)
    }

    required convenience init?(first firstEvent: TestAggregateRootCreated, other events: [any DDDCore.DomainEvent]) throws {
        self.init(id: firstEvent.aggregateId)
        try self.apply(events: events)
    }

    func when(happened event: some DDDCore.DomainEvent) throws {
        
    }

    
}


struct Mapper: EventTypeMapper {
    func mapping(eventType: String, payload: Data) -> (any DDDCore.DomainEvent)? {
        return nil
    }
}

class TestRepository: EventSourcingRepository {
    typealias AggregateRootType = TestAggregateRoot
    typealias StorageCoordinator = KurrentStorageCoordinator<TestAggregateRoot,Mapper>

    var coordinator: StorageCoordinator

    init() throws {
        let client = try EventStoreDBClient(settings: .localhost())
        self.coordinator = .init(mapper: Mapper(), client: client)
    }
}

final class DDDCoreTests: XCTestCase {
    func testExample() throws {
        // XCTest Documentation
        // https://developer.apple.com/documentation/xctest

        // Defining Test Cases and Test Methods
        // https://developer.apple.com/documentation/xctest/defining_test_cases_and_test_methods
        
        
//        KurrentStorageCoordinator.init(mapper: , client: <#T##EventStoreDBClient#>)



    }
}
