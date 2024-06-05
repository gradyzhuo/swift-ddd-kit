//
//  Repository.swift
//
//
//  Created by Grady Zhuo on 2024/6/2.
//

import Foundation

public protocol Repository {
    associatedtype T: AggregateRoot

    func findBy(id: T.ID) async throws -> T?
    func save(aggregateRoot: T) async throws
    func delete(aggregateRoot: T) async throws
}


