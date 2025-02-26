//
//  AggregateRootMetadata.swift
//
//
//  Created by Grady Zhuo on 2024/6/4.
//

import Foundation

public class AggregateRootMetadata {
    var events: [any DomainEvent] = []

    public package(set) var deleted: Bool
    public package(set) var version: UInt64?

    public init() {
        deleted = false
        version = nil
    }
}
