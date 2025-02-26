//
//  EventSourcingRepository.swift
//  DDDKit
//
//  Created by Grady Zhuo on 2025/2/25.
//
import Foundation
import DDDCore
import EventSourcing

extension EventSourcingRepository {
    public func save(aggregateRoot: AggregateRootType, userId: String) async throws {
        let customMetadata = CustomMetadata(
            className: "\(type(of: aggregateRoot))",
            userId: userId)
        let encoder = JSONEncoder()
        try await self.save(aggregateRoot: aggregateRoot, customMetadata: encoder.encode(customMetadata))
    }
}

