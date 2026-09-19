//
//  DemoDomainEvent.swift
//  NotificationDefinitionDemo
//
//  A minimal hand-written `DomainEvent` conformance — proves the generated per-entry
//  notification protocols work against a REAL domain event, not a synthesized flat struct. Real
//  contexts generate their events via `DomainEventGenerator`'s `event.yaml` DSL; this demo
//  hand-writes one instead, to avoid pulling that second codegen pipeline into this demo target.
//

import DDDCore
import Foundation

public struct DemoMetadata: Codable, Sendable {
    public let operatorId: String
    public init(operatorId: String) {
        self.operatorId = operatorId
    }
}

public struct CollaboratorAddedEvent: DomainEvent {
    public typealias Metadata = DemoMetadata

    public let id: UUID
    public let collaboratorId: String
    public let quotingCaseGroupingId: String
    public var metadata: Metadata?
    public let aggregateRootId: String
    public let occurred: Date

    public init(
        id: UUID = UUID(),
        collaboratorId: String,
        quotingCaseGroupingId: String,
        metadata: Metadata? = nil,
        aggregateRootId: String,
        occurred: Date = .now
    ) {
        self.id = id
        self.collaboratorId = collaboratorId
        self.quotingCaseGroupingId = quotingCaseGroupingId
        self.metadata = metadata
        self.aggregateRootId = aggregateRootId
        self.occurred = occurred
    }
}
