//
//  CrossAggregateEventTypeMapper.swift
//  DDDKit
//
//  Created by Grady Zhuo on 2026/2/12.
//
import DDDCore

struct CrossAggregateEventTypeMapper: EventTypeMapper {
    let eventMappers: [any EventTypeMapper]

    public func mapping(eventData: any RecordedEventLike) throws -> (any DomainEvent)? {
        for eventMapper in eventMappers {
            guard let event = try eventMapper.mapping(eventData: eventData) else {
                continue
            }
            return event
        }
        return nil
    }
    
    public init(eventMappers: [any EventTypeMapper]){
        self.eventMappers = eventMappers
    }
}
