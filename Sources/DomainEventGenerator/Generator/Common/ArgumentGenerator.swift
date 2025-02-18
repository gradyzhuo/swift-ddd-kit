//
//  ArgumentGenerator.swift
//  
//
//  Created by 卓俊諺 on 2025/2/11.
//

package struct ArgumentGenerator {
    let definition: PropertyDefinition
    
    init(definition: PropertyDefinition) {
        self.definition = definition
    }
    
    func render() -> String {
        var columns: [String] = [ ]
        
        columns.append("\(definition.name): \(definition.type.name)")
        if let defaultValue = definition.default {
            columns.append("= \(defaultValue)")
        }
        return columns.joined(separator: " ")
    }
}
