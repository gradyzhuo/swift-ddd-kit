//
//  CollaboratorAddedNotifications.swift
//  NotificationDefinitionDemo
//
//  Hand-written conformers to the GENERATED per-entry protocols (from notification.yaml's
//  `collaborator-added-mail`/`collaborator-added-in-app` entries, produced by
//  NotificationGeneratorPlugin). The mail conformer doesn't override `render()` (exercises the
//  protocol extension's default implementation); the inApp conformer DOES override it, proving a
//  conformer's own `render(variables:)` is correctly selected over the extension's default —
//  which would NOT happen if `render` were declared only in the extension, not as a protocol
//  requirement.
//

import NotificationDefinition

public struct CollaboratorAddedMailNotification: CollaboratorAddedNotificationCollaborator_Added_MailProtocol {
    public let event: CollaboratorAddedEvent
    public var quotingCaseGroupingId: String { event.quotingCaseGroupingId }
    public var collaboratorId: String { event.collaboratorId }

    public init(event: CollaboratorAddedEvent) {
        self.event = event
    }

    public func recipients() async throws -> [String] {
        [event.collaboratorId]
    }
}

public struct CollaboratorAddedInAppNotification: CollaboratorAddedNotificationCollaborator_Added_In_AppProtocol {
    public let event: CollaboratorAddedEvent
    public var quotingCaseGroupingId: String { event.quotingCaseGroupingId }
    public var collaboratorId: String { event.collaboratorId }

    public init(event: CollaboratorAddedEvent) {
        self.event = event
    }

    public func recipients() async throws -> [String] {
        [event.collaboratorId]
    }

    public func render(variables: some DemoNotificationVariables) async throws -> RenderedNotification {
        RenderedNotification(
            type: .inApp,
            recipients: try await self.recipients(),
            fields: ["title": "OVERRIDDEN", "content": "OVERRIDDEN", "render": "plaintext"])
    }
}
