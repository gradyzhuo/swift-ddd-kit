//
//  EventTypeHandler.swift
//  DDDKit
//
//  Created by Grady Zhuo on 2025/6/6.
//
import DDDCore
import Foundation
import KurrentDB

struct AnyDomainEvent: DomainEvent {
    var metadata: [String : String]?
    
    typealias Metadata = [String:String]
    
    
    var aggregateRootId: String = ""
    var occurred: Date = .now
    var id: UUID = .init()
}

public struct EventTypeHandler<EventType: DomainEvent, AggregateRootType: AggregateRoot, UserInfoType: Sendable>: MigrationHandler{
    public var action: @Sendable (AggregateRootType, EventType, UserInfoType) throws -> Void
    
    init(action: @escaping @Sendable (AggregateRootType, EventType, UserInfoType) throws -> Void) {
        self.action = action
    }
}

extension EventTypeHandler where EventType == AnyDomainEvent {
    init(action: @escaping @Sendable (AggregateRootType, any DomainEvent, UserInfoType) throws -> Void) {
        self.action = action
    }
}
