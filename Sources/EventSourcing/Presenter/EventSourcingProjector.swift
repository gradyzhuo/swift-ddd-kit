//
//  EventSourcingProjector.swift
//  DDDKit
//
//  Created by Grady Zhuo on 2025/10/28.
//

import DDDCore
@available(*, deprecated, renamed: "EventStorageProjector")
public protocol EventSourcingProjector<StorageCoordinator>: Projector {
    associatedtype StorageCoordinator: EventStorageCoordinator<ProjectableType>

    var coordinator: StorageCoordinator { get }
}

extension EventSourcingProjector {

    public func find(byId id: ProjectableType.ID) async throws -> ProjectableType? {
        guard let fetechedEvents = try await coordinator.fetchEvents(byId: id) else {
            return nil
        }
        
        let projectable = try await ProjectableType(events: fetechedEvents.events)
        return projectable
    }
}
