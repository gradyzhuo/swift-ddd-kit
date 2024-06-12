//
//  Repository.swift
//
//
//  Created by Grady Zhuo on 2024/6/2.
//

import Foundation

public protocol Repository: AnyObject {
    associatedtype AggregateRootType: AggregateRoot

    func find(byId id: AggregateRootType.ID) async throws -> AggregateRootType?
    func save(aggregateRoot: AggregateRootType) async throws
    func delete(aggregateRoot: AggregateRootType) async throws
    
}
