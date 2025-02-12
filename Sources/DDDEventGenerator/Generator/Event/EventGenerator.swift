//
//  EventGenerator.swift
//  DDDKit
//
//  Created by Grady Zhuo on 2025/2/11.
//
import Foundation
import Yams

package struct EventGenerator {
    let definitions: [String: EventDefinition]
    
    package init(definitions: [String: EventDefinition]){
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
    
    package func render(accessLevel: AccessLevel) -> [String] {
        var lines: [String] = []

        for (eventName, definition) in definitions {
            let eventGenerator = EventStructureGenerator(eventName: eventName, definition: definition)
            lines.append(contentsOf: eventGenerator.render(accessLevel: accessLevel))
            lines.append("")
            
            //extension
            let extensionGenerator = EventAggregateRootIdExtensionGenerator(eventName: eventName, definition: definition)
            lines.append(contentsOf: extensionGenerator.render(accessLevel: accessLevel))
            lines.append("")
            
            if let migration = definition.migration {
                let migrationGenerator = EventMigrationExtensionGenerator(eventName: eventName, definition: migration)
                lines.append(contentsOf: migrationGenerator.render(accessLevel: accessLevel))
            }
            lines.append("")
        }
        return lines
    }
}
