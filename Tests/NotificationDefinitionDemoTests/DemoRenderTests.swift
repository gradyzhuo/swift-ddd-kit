//
//  DemoRenderTests.swift
//  NotificationDefinitionDemoTests
//
//  Renders `CollaboratorAdded` through the GENERATED code (variables protocol +
//  notification input/render, produced by VariablesGeneratorPlugin /
//  NotificationGeneratorPlugin from Sources/NotificationDefinitionDemo's yamls)
//  using the hand-written `DemoVariables` stub. This is the end-to-end proof
//  that the notification-definition codegen chain compiles AND behaves.
//

import Foundation
import Testing

@testable import NotificationDefinitionDemo
import NotificationDefinition

@Suite("DemoRender")
struct DemoRenderTests {

    private func makeInput(json: String) throws -> CollaboratorAddedNotificationInput {
        try JSONDecoder().decode(CollaboratorAddedNotificationInput.self, from: Data(json.utf8))
    }

    @Test func rendersTwoNotificationsInYamlOrder() async throws {
        let input = try makeInput(json: """
        {"collaboratorId": "collaborator-1", "quotingCaseGroupingId": "case-1"}
        """)

        let rendered = try await CollaboratorAddedNotification.render(input: input, variables: DemoVariables())

        #expect(rendered.count == 2)
        #expect(rendered[0].type == .mail)
        #expect(rendered[1].type == .inApp)
    }

    @Test func mailFieldsAreSubstitutedExactly() async throws {
        let input = try makeInput(json: """
        {"collaboratorId": "collaborator-1", "quotingCaseGroupingId": "case-1"}
        """)

        let rendered = try await CollaboratorAddedNotification.render(input: input, variables: DemoVariables())
        let mail = rendered[0]

        #expect(mail.fields["subject"] == "你已被加入案件「6666」")
        // The mail `content` field is authored as Markdown (a `content: |` block scalar in
        // notification.yaml) and rendered to safe HTML by the generated `render()` — see
        // docs/superpowers/specs/2026-09-09-markdown-notification-content-design.md §3-4.
        // The single paragraph becomes one `<p>` element; the YAML block scalar's trailing
        // `\n` is consumed by Markdown block parsing, not preserved in the rendered HTML.
        #expect(mail.fields["content"] == "<p>你以「編輯者」角色被加入案件「6666」，歡迎加入團隊。</p>")
        // mail never carries a `render` wire field — its render choice is fully resolved into
        // HTML upstream (see spec §4).
        #expect(mail.fields["render"] == nil)
    }

    @Test func inAppFieldsAreSubstitutedExactly() async throws {
        let input = try makeInput(json: """
        {"collaboratorId": "collaborator-1", "quotingCaseGroupingId": "case-1"}
        """)

        let rendered = try await CollaboratorAddedNotification.render(input: input, variables: DemoVariables())
        let inApp = rendered[1]

        #expect(inApp.fields["title"] == "你已被加入案件「6666」")
        // notification.yaml declares no `render:` key for this entry, so it gets the new
        // per-channel default: inApp -> plaintext (see
        // docs/superpowers/specs/2026-09-15-inapp-render-format-design.md §2). Plaintext skips
        // Markdown parsing entirely, so the substituted string comes back verbatim, no `<p>`
        // wrapping.
        #expect(inApp.fields["content"] == "你以「編輯者」角色被加入案件「6666」。")
        #expect(inApp.fields["render"] == "plaintext")
    }

    @Test func recipientsIsCollaboratorId() async throws {
        let input = try makeInput(json: """
        {"collaboratorId": "collaborator-42", "quotingCaseGroupingId": "case-1"}
        """)

        let rendered = try await CollaboratorAddedNotification.render(input: input, variables: DemoVariables())

        #expect(rendered[0].recipients == [input.collaboratorId])
        #expect(rendered[1].recipients == [input.collaboratorId])
    }

    @Test func decodingFailsWhenAnInputIsMissing() {
        // `quotingCaseGroupingId` omitted entirely.
        let json = """
        {"collaboratorId": "collaborator-1"}
        """
        #expect(throws: (any Error).self) {
            _ = try makeInput(json: json)
        }
    }
}
