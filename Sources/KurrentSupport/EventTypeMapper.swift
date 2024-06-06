//
//  EventTypeMapper.swift
//
//
//  Created by Grady Zhuo on 2024/6/6.
//

import DDDCore
import EventSourcing
import EventStoreDB
import Foundation

public protocol EventTypeMapper {
    func mapping(eventData: RecordedEvent) throws -> (any DomainEvent)?
}
