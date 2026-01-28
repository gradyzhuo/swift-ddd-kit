//
//  Untitled.swift
//  DDDKit
//
//  Created by Grady Zhuo on 2025/10/23.
//
import Foundation
import Testing
import DDDCore
@testable import EventSourcing
import KurrentSupport

struct TestCreated: DomainEvent{
    var aggregateRootId: String
    
    var occurred: Date
    
    var id: UUID
    var value: String
    
    
    init(id: UUID = .init(), aggregateRootId: String, value: String, occurred: Date = .now,) {
        self.id = id
        self.aggregateRootId = aggregateRootId
        self.value = value
        self.occurred = occurred
    }

}

struct TestEdited: DomainEvent{
    var aggregateRootId: String
    
    var occurred: Date
    
    var id: UUID
    var value: String
    
    init(id: UUID = .init(), aggregateRootId: String, value: String, occurred: Date = .now,) {
        self.id = id
        self.aggregateRootId = aggregateRootId
        self.value = value
        self.occurred = occurred
    }

}



actor TestPresenter: @preconcurrency EventSourcingPresenter {
    var readModel: ReadModel?
    
    var id: String
    
    init(id: String) {
        self.id = id
        self.readModel = nil
    }

    func when(happened event: some DDDCore.DomainEvent) throws {
        switch event {
        case let event as TestCreated:
            readModel = ReadModel(testAggregateRootId: event.aggregateRootId, value: event.value)
        case let event as TestEdited:
            readModel?.value = event.value
        default:
            return
        }
    }
}


extension TestPresenter{
    struct ReadModel: Codable, Sendable {
        var testAggregateRootId: String
        var value: String
    }
}

final class TestCoordinator: EventStorageCoordinator{
    typealias ProjectableType = TestPresenter
    
    func fetchEvents(byId id: String) async throws -> (events: [any DDDCore.DomainEvent], latestRevision: UInt64)? {
        guard id == "test" else {
            return nil
        }
        
        let events: [any DomainEvent] = [
            TestCreated(aggregateRootId: "hello", value: "world"),
            TestEdited(aggregateRootId: "hello", value: "world2"),
        ]
        return (events: events, latestRevision: UInt64(events.count))
    }
    
    func append(events: [any DDDCore.DomainEvent], byId id: String, version: UInt64?, external: [String : String]?) async throws -> UInt64? {
        return nil
    }
}

actor TestProjector: EventSourcingProjector{
    typealias StorageCoordinator = TestCoordinator
    
    var coordinator: TestCoordinator
    
    init(coordinator: TestCoordinator) {
        self.coordinator = coordinator
    }
}


@Test func testPresenter() async throws {
    let readModel = try await TestPresenter.buildReadModel(id: "test", events: [
        TestCreated(aggregateRootId: "hello", value: "world"),
        TestEdited(aggregateRootId: "hello", value: "world2"),
    ])
    #expect(readModel?.testAggregateRootId == "hello")
    #expect(readModel?.value == "world2")
}


@Test func testProjector() async throws {
    
    let projector = TestProjector(coordinator: .init())
    let readModel = try await projector.find(byId: "test")
    
    #expect(readModel?.testAggregateRootId == "hello")
    #expect(readModel?.value == "world2")
}

@Test func testProjector2() async throws {
    let projector = TestProjector(coordinator: .init())
    let readModel = try await projector.find(byId: "test2")
    
    #expect(readModel == nil)
    #expect(readModel == nil)
}
