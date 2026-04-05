//
//  AggregateHelperGenerator.swift
//  DDDKit
//
//  Created by Grady Zhuo on 2025/2/12.
//

import Foundation
import Yams

package struct AggregateRootGenerator {
    package let wrappedDefinition: (String, EventProjectionDefinition)
    
    package init(aggregateRootName: String, aggregateEvents: EventDefinitionCollection) throws {
        
        let createdEvents = aggregateEvents.getValidEvents(kind: .createdEvent)
        let deletedEvent = aggregateEvents.getValidEvent(kind: .deletedEvent)
        

        let aggregateEventNames = aggregateEvents.events.filter{ e in !createdEvents.contains(where: { event in event.name == e.name}) && e.name != deletedEvent?.name }.map(\.name)
        
        let aggregateRootProjectionModel = EventProjectionDefinition(model: .aggregateRoot, kurrentDBEvents: aggregateEventNames.map { .plain($0) }, createdKurrentDBEvents: createdEvents.map{ .plain($0.name) }, deletedEvent: deletedEvent?.name)
        
        self.wrappedDefinition = (aggregateRootName, aggregateRootProjectionModel)
    }
    
    package init(aggregateRootName: String, aggregateEventsYamlFileURL: URL) throws {
        let yamlDecoder = YAMLDecoder()
        let aggregateEventsData = try Data(contentsOf: aggregateEventsYamlFileURL)
        let aggregateEventsDefinitions = try yamlDecoder.decode(EventDefinitionCollection.self, from: aggregateEventsData)
        try self.init(aggregateRootName: aggregateRootName, aggregateEvents: aggregateEventsDefinitions)
    }
    
    package func render(accessLevel: AccessLevel) -> [String] {
        var lines: [String] = []
        
        let (modelName, definition) = self.wrappedDefinition
        
        let protocolName = "\(modelName)Protocol"
        
        let createdEvents = definition.createdEvents

        var whereExpression = "ID == \(definition.idType.name)"
        if let deletedEvent = definition.deletedEvent{
            whereExpression = whereExpression + ", DeletedEventType == \(deletedEvent)"
        }
        
        lines.append("\(accessLevel.rawValue) protocol \(protocolName): AggregateRoot where \(whereExpression){")
        
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
        
        return lines
    }
}


enum AggregateRootGeneratorError: Error{
    case invalidCreatedEvent
}
