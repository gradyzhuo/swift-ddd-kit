//
//  AggregateHelperGenerator.swift
//  DDDKit
//
//  Created by Grady Zhuo on 2025/2/12.
//

import Foundation
import Yams

package struct ProjectionModelGenerator {
    package let definitions: [String: EventProjectionDefinition]
    
    package init(definitions: [String: EventProjectionDefinition], aggregateRootName: String, aggregateEvents: EventDefinitionCollection) throws {
        
        guard let createdEvent = aggregateEvents.getValidEvent(kind: .createdEvent) else {
            throw ProjectionModelGeneratorError.invalidCreatedEvent
        }
        let deletedEvent = aggregateEvents.getValidEvent(kind: .deletedEvent)
        
        let filteredDefinitions = definitions.filter{ $0.value.model != .aggregateRoot }
        
        let aggregateEventNames = aggregateEvents.events.filter{ $0.name != createdEvent.name && $0.name != deletedEvent?.name }.map{ $0.name }
        
        let aggregateRootProjectionModel = EventProjectionDefinition(model: .aggregateRoot, createdEvent: createdEvent.name, deletedEvent: deletedEvent?.name, events: aggregateEventNames)
        
        self.definitions = filteredDefinitions.merging([(aggregateRootName, aggregateRootProjectionModel)]) { lhs, rhs in
            return lhs
        }
    }
    
    package init(projectionModelYamlFileURL: URL, aggregateRootName: String, aggregateEventsYamlFileURL: URL) throws {
        let yamlData = try Data(contentsOf: projectionModelYamlFileURL)
        let yamlDecoder = YAMLDecoder()
        let definitions = try yamlDecoder.decode([String: EventProjectionDefinition].self, from: yamlData)
        
        let aggregateEventsData = try Data(contentsOf: aggregateEventsYamlFileURL)
        let aggregateEventsDefinitions = try yamlDecoder.decode(EventDefinitionCollection.self, from: aggregateEventsData)
        
        try self.init(definitions: definitions, aggregateRootName: aggregateRootName, aggregateEvents: aggregateEventsDefinitions)
    }
    
    package func render(accessLevel: AccessLevel) -> [String] {
        var lines: [String] = []
        
        for (modelName, definition) in definitions{
            let protocolName = "\(modelName)\(definition.model.suffix)Protocol"
            lines.append("\(accessLevel.rawValue) protocol \(protocolName) {")
            for eventName in definition.events{
                lines.append("   func when(event: \(eventName)) throws")
            }
            lines.append("}")
            lines.append("")
            
            //created
            lines.append("extension \(protocolName) where Self: \(definition.model.protocol) {")
            lines.append("    \(accessLevel.rawValue) typealias ID = \(definition.idType.name)")
            
            let createdEvent = definition.createdEvent
            lines.append("    \(accessLevel.rawValue) typealias CreatedEventType = \(createdEvent)")
            
            if let deletedEvent = definition.deletedEvent{
                lines.append("    \(accessLevel.rawValue) typealias DeletedEventType = \(deletedEvent)")
            }
            lines.append("}")
            lines.append("")
            
            //whens
            lines.append("""
extension \(protocolName) where Self: \(definition.model.protocol){
    \(accessLevel) func when(happened event: some DomainEvent) throws{
        switch event {
""")
            
            for eventName in definition.events{
                lines.append("""
            case let event as \(eventName):
            try when(event: event)
""")
            }
            lines.append("""
            default:
            break
""")
            lines.append("        }")
            lines.append("    }")
            lines.append("}")
            lines.append("")
        }
        
        return lines
    }
}


enum ProjectionModelGeneratorError: Error{
    case invalidCreatedEvent
}
