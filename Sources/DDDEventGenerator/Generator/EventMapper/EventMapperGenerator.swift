//
//  EventMapperGenerator.swift
//  
//
//  Created by 卓俊諺 on 2025/2/11.
//

import Foundation
import Yams

package struct EventMapperGenerator {
    let definitions: [String: EventDefinition]
    
    package init(definitions: [String: EventDefinition]) {
        self.definitions = definitions
    }
    
    package init(yamlFileURL: URL) throws {
        let yamlData = try Data(contentsOf: yamlFileURL)
        let yamlDecoder = YAMLDecoder()
        let definitions = try yamlDecoder.decode([String: EventDefinition].self, from: yamlData)
        self.init(definitions: definitions)
    }
    
    package init(yamlFilePath: String) throws {
        let url = URL(fileURLWithPath: yamlFilePath)
        try self.init(yamlFileURL: url)
    }
    
    package func render(accessLevel: AccessLevel)-> [String] {
        var lines: [String] = []
        
        lines.append("""
\(accessLevel.rawValue) struct EventMapper: EventTypeMapper {

    \(accessLevel.rawValue) init(){}

    \(accessLevel.rawValue) func mapping(eventData: RecordedEvent) throws -> (any DomainEvent)? {
""")
        
        lines.append("""
        return switch eventData.mappingClassName {
""")
        
        for (eventName, _) in definitions {
            lines.append("""
        case "\\(\(eventName).self)":
            try eventData.decode(to: \(eventName).self)
""")
        }
        
        lines.append("""
        default:
            nil
""")
//        case "\(LetterContentEdited.self)":
//            try eventData.decode(to: LetterContentEdited.self)
//        case "\(PaymentItemAdded.self)":
//            try eventData.decode(to: PaymentItemAdded.self)
//        default:
//            nil
        
        lines.append("""
        }
    }
}
""")
        return lines
    }
}
