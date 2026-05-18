//
//  EventSourcingRepository.swift
//  DDDKit
//
//  Created by Grady Zhuo on 2025/2/25.
//
import Foundation
import DDDCore
import EventSourcing

// NOTE: The userId convenience overloads (save(aggregateRoot:userId:) and
// delete(byId:userId:)) have been removed. The equivalent pattern is now:
//
//   let metadata = CustomMetadata(className: ..., external: ["userId": userId])
//   try await EventMetadataContext<CustomMetadata>.withValue(metadata) {
//       try await repository.save(aggregateRoot: aggregateRoot)
//   }
