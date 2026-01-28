//
//  EventAggregateRootIdExtensionGenerator.swift
//  
//
//  Created by 卓俊諺 on 2025/2/11.
//

package struct EventAggregateRootIdExtensionGenerator {
    let event: Event
    
    init(event: Event) {
        self.event = event
    }
    
    func render(accessLevel: AccessLevel = .internal)-> [String] {
        var lines: [String] = []
        guard let aggregateRootId = self.event.definition.aggregateRootId else {
            return lines
        }
        lines.append("""
extension \(event.name): Codable{
    \(accessLevel.rawValue) var aggregateRootId: String{
        get{
            \(aggregateRootId.alias)
        }
    }
}
""")
        return lines
    }
}
