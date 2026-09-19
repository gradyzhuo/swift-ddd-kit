//
//  DemoRenderTests.swift
//  NotificationDefinitionDemoTests
//
//  Exercises the generated per-entry protocols (produced by NotificationGeneratorPlugin from
//  Sources/NotificationDefinitionDemo's yamls) against a real `DomainEvent`-conforming type,
//  using the hand-written `DemoVariables` stub for the environment-variable protocol. This is the
//  end-to-end proof that the notification-definition codegen chain compiles AND behaves for the
//  new per-entry-protocol design.
//

import Foundation
import Testing

@testable import NotificationDefinitionDemo
import NotificationDefinition

@Suite("DemoRender")
struct DemoRenderTests {

    private func makeEvent(
        collaboratorId: String = "collaborator-1", quotingCaseGroupingId: String = "case-1"
    ) -> CollaboratorAddedEvent {
        CollaboratorAddedEvent(
            collaboratorId: collaboratorId,
            quotingCaseGroupingId: quotingCaseGroupingId,
            aggregateRootId: quotingCaseGroupingId)
    }

    // Calling `.render(variables:)` directly on a value whose STATIC type is the concrete
    // `CollaboratorAddedInAppNotification` struct would resolve to that struct's own method no
    // matter whether `render` is a protocol requirement or only an extension default — Swift
    // always prefers a concrete type's own member over an extension in that case. Routing the
    // call through a generic parameter constrained to the protocol forces dispatch through the
    // protocol's witness table instead, which is the only way to actually distinguish "requirement
    // overridden by the conformer" from "unrelated same-signature method shadowing an
    // extension-only default".
    private func renderThroughProtocol<T: CollaboratorAddedNotificationCollaborator_Added_In_AppProtocol>(
        _ notification: T, variables: DemoVariables
    ) async throws -> RenderedNotification {
        try await notification.render(variables: variables)
    }

    @Test func mailUsesDefaultRenderAndSubstitutesFieldsExactly() async throws {
        let notification = CollaboratorAddedMailNotification(event: makeEvent())
        let rendered = try await notification.render(variables: DemoVariables())

        #expect(rendered.type == .mail)
        #expect(rendered.recipients == ["collaborator-1"])
        #expect(rendered.fields["subject"] == "你已被加入案件「6666」")
        // The mail `content` field is authored as Markdown (a `content: |` block scalar) and
        // rendered to safe HTML by the generated default `render()` — see
        // docs/superpowers/specs/2026-09-09-markdown-notification-content-design.md §3-4.
        #expect(rendered.fields["content"] == "<p>你以「編輯者」角色被加入案件「6666」，歡迎加入團隊。</p>")
        // mail never carries a `render` wire field.
        #expect(rendered.fields["render"] == nil)
    }

    @Test func inAppOverriddenRenderIsSelectedOverDefault() async throws {
        // Proves render(variables:) being a protocol requirement (not only an extension method)
        // means this conformer's own implementation is what actually runs. The call is routed
        // through `renderThroughProtocol` (generic over the protocol) rather than called directly
        // on `notification` — a direct call on the concrete struct's static type would select its
        // own `render` regardless of requirement-vs-extension-only, so it wouldn't discriminate
        // the two cases. Going through the protocol abstraction does: if `render` were declared
        // only in the protocol extension (not as a requirement), this call would resolve to the
        // extension's default implementation instead, and the assertions below would fail.
        let notification = CollaboratorAddedInAppNotification(event: makeEvent())
        let rendered = try await renderThroughProtocol(notification, variables: DemoVariables())

        #expect(rendered.type == .inApp)
        #expect(rendered.fields["title"] == "OVERRIDDEN")
        #expect(rendered.fields["content"] == "OVERRIDDEN")
        #expect(rendered.recipients == ["collaborator-1"])
    }

    @Test func recipientsComeFromTheRealDomainEventField() async throws {
        let notification = CollaboratorAddedMailNotification(event: makeEvent(collaboratorId: "collaborator-42"))
        let rendered = try await notification.render(variables: DemoVariables())
        #expect(rendered.recipients == ["collaborator-42"])
    }

    @Test func metadataIsAccessibleOnTheRealDomainEvent() async throws {
        // Not exercised by CollaboratorAddedMailNotification's recipients() today (it doesn't
        // need metadata), but confirms the real event's `.metadata` — inaccessible in the old
        // Input-struct design — is reachable through `event` on the conforming type.
        var event = makeEvent()
        event.metadata = DemoMetadata(operatorId: "operator-9")
        let notification = CollaboratorAddedMailNotification(event: event)
        #expect(notification.event.metadata?.operatorId == "operator-9")
    }
}
