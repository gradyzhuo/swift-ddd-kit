//
//  EventMapperGenerator.swift
//  
//
//  Created by 卓俊諺 on 2025/2/11.
//

import Foundation
import Yams

package struct EventMapperGenerator {
    let modelName: String
    let eventNames: [String]
    
    package init(modelName: String, eventNames: [String]) {
        self.modelName = modelName
        self.eventNames = eventNames
    }
    
    package func render(accessLevel: AccessLevel)-> [String] {
        var lines: [String] = []
        
        lines.append("""
\(accessLevel.rawValue) struct \(modelName)EventMapper: EventTypeMapper {

    \(accessLevel.rawValue) init(){}

    \(accessLevel.rawValue) func mapping(eventData: any RecordedEventLike) throws -> (any DomainEvent)? {
""")
        
        lines.append("""
        return switch eventData.eventType {
""")
        
        for eventName in eventNames {
            lines.append("""
        case "\(eventName)":
            try {
                guard var event = try eventData.decode(to: \(eventName).self) else { return nil }
                // handle metadata — tolerate empty bytes (no ambient on write) and
                // decode failure (Store.Metadata ≠ event.Metadata mismatch) by
                // leaving event.metadata nil
                if !eventData.customMetadata.isEmpty {
                    let decoder = JSONDecoder()
                    event.metadata = try? decoder.decode(\(eventName).Metadata.self, from: eventData.customMetadata)
                }
                return event
            }()
""")
        }
        
        lines.append("""
        default:
            nil
""")
        
        lines.append("""
        }
    }
}
""")
        return lines
    }
}
