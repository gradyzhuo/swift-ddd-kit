//
//  PropertyGenerator.swift
//  
//
//  Created by 卓俊諺 on 2025/2/11.
//

package struct PropertyGenerator {
    let definition: PropertyDefinition
    
    init(definition: PropertyDefinition) {
        self.definition = definition
    }
    
    func render(accessLevel: AccessLevel) -> String {
        var columns: [String] = [ ]

        columns.append(accessLevel.rawValue)
        
        columns.append("let")
        
        columns.append("\(definition.name): \(definition.type.name)")
        return columns.joined(separator: " ")
    }
}
