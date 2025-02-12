//
//  Generator.swift
//  
//
//  Created by 卓俊諺 on 2025/2/11.
//

protocol Generator {
    func render() -> [String]
}

extension Generator {
    func indentation(count: Int)->String {
        return String(repeating: " ", count: count)
    }
    
}
