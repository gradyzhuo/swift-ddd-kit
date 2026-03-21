//
//  MigrationUtility.swift
//  DDDKit
//
//  Created by Grady Zhuo on 2025/6/6.
//
import DDDCore
import EventSourcing
import KurrentSupport
import KurrentDB
import Foundation

public protocol Migration: Sendable {
    associatedtype CreatedEvent: DomainEvent
    associatedtype AggregateRootType: AggregateRoot
    associatedtype EventMapper: EventTypeMapper
    associatedtype UserInfoType: Sendable
    typealias CreatedHandler = @Sendable (_ createdEvent: CreatedEvent, _ userInfo: UserInfoType?) throws -> AggregateRootType?
    
    var eventMapper: EventMapper { get }
    var createdHandler: CreatedHandler? { get }
    var handlers: [any MigrationHandler] { get }
    var userInfo: UserInfoType? { get }
    
    init(eventMapper: EventMapper, handlers: [any MigrationHandler], createdHandler: CreatedHandler?, userInfo: UserInfoType?)
}

extension Migration {
    public func migrate(responses: Streams<SpecifiedStream>.Read.Responses) async throws -> AggregateRootType?{
        let records = try await responses.reduce(into: [RecordedEvent]()) { partialResult, response in
            let record = try response.event.record
            partialResult.append(record)
        }
        return try await migrate(records: records)
    }
    
    public func migrate(records: [RecordedEvent]) async throws -> AggregateRootType? {
        
        guard let createdRecordedEvent = records.first else {
            return nil
        }
        
        guard let aggregateRoot = try await initAggregateRoot(recorded: createdRecordedEvent) else {
            return nil
        }
        
        let records = records.dropFirst()
        
        for record in records {
            var handled: Bool = false
                    
            for handler in self.handlers {
                guard let event = handler.decode(recordedEvent: record)  else {
                    continue
                }
                let result = try handleEvent(aggregateRoot: aggregateRoot, handler: handler, event: event)
                if result {
                    handled = result
                    break
                }
            }
            
            if !handled {
                guard let event = try eventMapper.mapping(eventData: record) else {
                    break
                }
                try aggregateRoot.apply(event: event)
            }
        }
        return aggregateRoot
    }
    
    public func initAggregateRoot(recorded: RecordedEvent) async throws -> AggregateRootType? {
        guard let oldEvent = try recorded.decode(to: CreatedEvent.self) else {
            return nil
        }
        
        guard let userInfo else {
            return nil
        }

        let createdHandler = self.createdHandler ?? { createdEvent, userInfo in
            let aggregateRoot = try AggregateRootType.init(events: [createdEvent])
            try aggregateRoot?.apply(event: createdEvent)
            return aggregateRoot
        }

        return try createdHandler(oldEvent, userInfo)
    }
    
    func handleEvent<Handler: MigrationHandler>(aggregateRoot: AggregateRootType, handler: Handler, event: any DomainEvent) throws -> Bool {
        
        guard
            let userInfo = userInfo as? Handler.UserInfoType,
            let aggregateRoot = aggregateRoot as? Handler.AggregateRootType
        else {
            return false
        }
        
        guard let event = event as? Handler.EventType else {
            return false
        }
        do{
            try handler.handle(aggregateRoot: aggregateRoot, event: event, userInfo: userInfo)
        }catch{
            throw MigrationError.event(error: error, event: event)
        }
        
        return true
    }
    
    
}
