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
        
        let createdEvents = aggregateEvents.getValidEvents(kind: .createdEvent)
        let deletedEvent = aggregateEvents.getValidEvent(kind: .deletedEvent)
        
        let filteredDefinitions = definitions.filter{ $0.value.model != .aggregateRoot }
        
        let aggregateEventNames = aggregateEvents.events.filter{ e in !createdEvents.contains(where: { event in event.name == e.name}) && e.name != deletedEvent?.name }.map(\.name)
        
        let aggregateRootProjectionModel = EventProjectionDefinition(model: .aggregateRoot, createdEvents: createdEvents.map{ $0.name }, deletedEvent: deletedEvent?.name, events: aggregateEventNames)
        
        self.definitions = filteredDefinitions.merging([(aggregateRootName, aggregateRootProjectionModel)]) { lhs, rhs in
            return lhs
        }
    }
    
    package init(projectionModelYamlFileURL: URL, aggregateRootName: String, aggregateEventsYamlFileURL: URL) throws {
        let yamlData = try Data(contentsOf: projectionModelYamlFileURL)

        let yamlDecoder = YAMLDecoder()
        var definitions: [String: EventProjectionDefinition]
        do{
            if yamlData.isEmpty {
                throw DomainEventGeneratorError.invalidYamlFile(url: projectionModelYamlFileURL, reason: "The yaml file is empty.")
            }
            
            definitions = try yamlDecoder.decode([String: EventProjectionDefinition].self, from: yamlData)
        }catch{
            definitions = [:]
        }
        let aggregateEventsData = try Data(contentsOf: aggregateEventsYamlFileURL)
        let aggregateEventsDefinitions = try yamlDecoder.decode(EventDefinitionCollection.self, from: aggregateEventsData)
        try self.init(definitions: definitions, aggregateRootName: aggregateRootName, aggregateEvents: aggregateEventsDefinitions)
    }
    
    package func renderAggregateRoot(accessLevel: AccessLevel, modelName: String, definition: EventProjectionDefinition){
        
        
        
    }
    
    
    
    package func render(accessLevel: AccessLevel) -> [String] {
        var lines: [String] = []
        
        for (modelName, definition) in definitions{
            
            let protocolName = "\(modelName)Protocol"
            
            let createdEvents = definition.createdEvents
            let deletedEvent = definition.deletedEvent
            
            var whereExpression = "ID == \(definition.idType.name)"
            //whereExpression = whereExpression// + ", CreatedEventType == \(createdEvent)"
            if let deletedEvent = definition.deletedEvent{
                whereExpression = whereExpression + ", DeletedEventType == \(deletedEvent)"
            }
            
            lines.append("\(accessLevel.rawValue) protocol \(protocolName):\(definition.model.protocol) where \(whereExpression){")
            
            for createdEvent in createdEvents {
                lines.append("   init?(first createdEvent: \(createdEvent), other events: [any DomainEvent]) throws")
            }
            
            for eventName in definition.events{
                lines.append("   func when(event: \(eventName)) throws")
            }
            if let deletedEvent = definition.deletedEvent {
                lines.append("   func when(event: \(deletedEvent)) throws")
            }
            lines.append("}")
            lines.append("")
            
            // `init` begin
            lines.append("extension \(protocolName) {")
            lines.append("""
    public init?(events: [any DomainEvent]) throws {
        var events = events
        let firstEvent = events.removeFirst()
        switch firstEvent {
""")
            for createdEvent in createdEvents {
                lines.append("""
        case let firstEvent as \(createdEvent):
            try self.init(first: firstEvent, other: events)
""")
            }
            lines.append("""
        default:
             return nil
        }
    }
""")
            lines.append("}")
            lines.append("")
            
            // `whens` begin
            lines.append("extension \(protocolName) {")
            
            
            lines.append("""
    \(accessLevel) func when(happened event: some DomainEvent) throws{
        switch event {
""")
            for eventName in definition.events{
                lines.append("""
            case let event as \(eventName):
            try when(event: event)
""")
            }
            if let deletedEvent = definition.deletedEvent {
                lines.append("""
            case let event as \(deletedEvent):
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
