//
//  EventTypeMapper.swift
//
//
//  Created by Grady Zhuo on 2024/6/6.
//

import DDDCore
import EventSourcing
import Foundation

public protocol EventTypeMapper: Sendable {
    func mapping(eventData: any RecordedEventLike) throws -> (any DomainEvent)?
}
