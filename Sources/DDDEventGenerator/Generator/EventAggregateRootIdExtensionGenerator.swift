//
//  EventAggregateRootIdExtensionGenerator.swift
//  
//
//  Created by 卓俊諺 on 2025/2/11.
//

package struct EventAggregateRootIdExtensionGenerator {
    let eventName: String
    let definition: EventDefinition
    
    init(eventName: String, definition: EventDefinition) {
        self.eventName = eventName
        self.definition = definition
    }
    
    func render(accessLevel: AccessLevel = .internal)-> [String] {
        var lines: [String] = []
        lines.append("""
extension \(eventName): Codable{
    \(accessLevel.rawValue) var aggregateRootId: String{
        get{
            \(definition.aggregateRootId.alias)
        }
    }
}
""")
        return lines
    }
}
