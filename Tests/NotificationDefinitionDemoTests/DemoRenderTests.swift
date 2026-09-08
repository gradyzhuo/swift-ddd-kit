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
        // The mail `content` field is authored as a `content: |` block scalar in
        // notification.yaml, which YAML clip-chomps to exactly one trailing `\n` —
        // preserved verbatim through generation and substitution (see task-3-report.md).
        #expect(mail.fields["content"] == "你以「編輯者」角色被加入案件「6666」，歡迎加入團隊。\n")
    }

    @Test func inAppFieldsAreSubstitutedExactly() async throws {
        let input = try makeInput(json: """
        {"collaboratorId": "collaborator-1", "quotingCaseGroupingId": "case-1"}
        """)

        let rendered = try await CollaboratorAddedNotification.render(input: input, variables: DemoVariables())
        let inApp = rendered[1]

        #expect(inApp.fields["title"] == "你已被加入案件「6666」")
        // Single-line `content:` scalar — no trailing newline, unlike the mail variant above.
        #expect(inApp.fields["content"] == "你以「編輯者」角色被加入案件「6666」。")
    }

    @Test func recipientsIsCollaboratorId() throws {
        let input = try makeInput(json: """
        {"collaboratorId": "collaborator-42", "quotingCaseGroupingId": "case-1"}
        """)

        #expect(CollaboratorAddedNotification.recipients(input: input) == [input.collaboratorId])
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
