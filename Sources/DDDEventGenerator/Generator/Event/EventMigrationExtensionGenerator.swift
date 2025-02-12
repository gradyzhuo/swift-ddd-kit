//
//  EventMigrationExtensionGenerator.swift
//  
//
//  Created by 卓俊諺 on 2025/2/11.
//

package struct EventMigrationExtensionGenerator {
    let eventName: String
    let definition: MigrationDefinition
    
    init(eventName: String, definition: MigrationDefinition) {
        self.eventName = eventName
        self.definition = definition
    }
    
    func render(accessLevel: AccessLevel, indentationCount: Int = 4)-> [String] {
        var lines: [String] = []
        lines.append("""
extension \(eventName){
    \(accessLevel.rawValue) var eventType: String {
        get {
            "\(definition.eventType)"
        }
    }
}
""")
        return lines
    }
}
