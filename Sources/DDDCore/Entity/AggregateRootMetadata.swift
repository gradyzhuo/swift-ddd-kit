//
//  AggregateRootMetadata.swift
//
//
//  Created by Grady Zhuo on 2024/6/4.
//

import Foundation

public class AggregateRootMetadata {
    var events: [any DomainEvent] = []

    public package(set) var isDeleted: Bool
    public package(set) var version: UInt?

    public init() {
        isDeleted = false
        version = nil
    }
}
