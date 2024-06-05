//
//  File.swift
//  
//
//  Created by Grady Zhuo on 2024/6/4.
//

import Foundation

public class AggregateRootMetadata {
    internal var events: [any DomainEvent] = []
    
    public package(set) var isDeleted: Bool
    public package(set) var version: UInt?
    
    public init() {
        self.isDeleted = false
        self.version = nil
    }
    
}
