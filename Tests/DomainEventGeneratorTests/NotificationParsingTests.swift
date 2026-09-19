import Testing
import Foundation
import Yams
@testable import DomainEventGenerator

@Suite("Notification YAML Parsing")
struct NotificationParsingTests {

    // Spec sample, updated for per-entry protocol `id`.
    static let specSampleYAML = """
    CollaboratorAdded:
      notifications:
        - id: collaborator-added-mail
          type: mail
          subject: 你已被加入案件「%QuotingCaseGroupName%」
          content: |
            你以「%QuotingCaseGroupCollaboratorRole%」角色被加入案件「%QuotingCaseGroupName%」，%CollaboratorDescription%。
        - id: collaborator-added-in-app
          type: inApp
          title: 你已被加入案件「%QuotingCaseGroupName%」
          content: 你以「%QuotingCaseGroupCollaboratorRole%」角色被加入案件「%QuotingCaseGroupName%」。
    """

    @Test("spec sample decodes: id per-entry, both notification types, exact fields")
    func specSampleDecodes() throws {
        let definitions = try NotificationDefinitionParser.parse(yaml: Self.specSampleYAML)
        #expect(definitions.count == 1)
        let definition = try #require(definitions.first)

        #expect(definition.eventName == "CollaboratorAdded")
        #expect(definition.notifications.count == 2)

        let mail = definition.notifications[0]
        #expect(mail.id == "collaborator-added-mail")
        #expect(mail.type == "mail")
        #expect(mail.fields.map(\.name) == ["subject", "content"])
        #expect(mail.fields[0].template == "你已被加入案件「%QuotingCaseGroupName%」")
        #expect(mail.fields[1].template.contains("%QuotingCaseGroupCollaboratorRole%"))
        #expect(mail.fields[1].template.contains("%QuotingCaseGroupName%"))
        #expect(mail.fields[1].template.contains("%CollaboratorDescription%"))

        let inApp = definition.notifications[1]
        #expect(inApp.id == "collaborator-added-in-app")
        #expect(inApp.type == "inApp")
        #expect(inApp.fields.map(\.name) == ["title", "content"])
        #expect(inApp.fields[0].template == "你已被加入案件「%QuotingCaseGroupName%」")
        #expect(inApp.fields[1].template == "你以「%QuotingCaseGroupCollaboratorRole%」角色被加入案件「%QuotingCaseGroupName%」。")
    }

    @Test("unknown notification type throws unknownType")
    func unknownTypeThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-entry
              type: push
              subject: hi
        """
        #expect(throws: NotificationParseError.unknownType(event: "SomeEvent", type: "push")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("duplicate notification type in the same event throws duplicateType")
    func duplicateTypeThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: first-mail
              type: mail
              subject: hi
              content: body
            - id: second-mail
              type: mail
              subject: hi again
              content: body again
        """
        #expect(throws: NotificationParseError.duplicateType(event: "SomeEvent", type: "mail")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("mail entry missing content throws missingField")
    func missingFieldThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-mail
              type: mail
              subject: hi
        """
        #expect(throws: NotificationParseError.missingField(event: "SomeEvent", type: "mail", field: "content")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("inApp entry missing title throws missingField")
    func missingFieldInAppThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-in-app
              type: inApp
              content: hi
        """
        #expect(throws: NotificationParseError.missingField(event: "SomeEvent", type: "inApp", field: "title")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("mail entry with extra field throws extraField")
    func extraFieldThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-mail
              type: mail
              subject: hi
              content: body
              cc: someone
        """
        #expect(throws: NotificationParseError.extraField(event: "SomeEvent", type: "mail", field: "cc")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("inApp entry with extra field throws extraField")
    func extraFieldInAppThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-in-app
              type: inApp
              title: hi
              content: body
              icon: bell
        """
        #expect(throws: NotificationParseError.extraField(event: "SomeEvent", type: "inApp", field: "icon")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("a recipients: key on an entry throws extraField — schema no longer supports it")
    func recipientsKeyThrowsExtraField() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-mail
              type: mail
              recipients:
                - userId
              subject: hi
              content: body
        """
        #expect(throws: NotificationParseError.extraField(event: "SomeEvent", type: "mail", field: "recipients")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("missing id key on entry throws missingId")
    func missingIdThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - type: mail
              subject: hi
              content: body
        """
        #expect(throws: NotificationParseError.missingId(event: "SomeEvent", type: "mail")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("empty id value on entry throws missingId")
    func emptyIdThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: ""
              type: mail
              subject: hi
              content: body
        """
        #expect(throws: NotificationParseError.missingId(event: "SomeEvent", type: "mail")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("id starting with an uppercase letter throws invalidId")
    func idStartingUppercaseThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: Some-Mail
              type: mail
              subject: hi
              content: body
        """
        #expect(throws: NotificationParseError.invalidId(event: "SomeEvent", id: "Some-Mail")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("id starting with a digit throws invalidId")
    func idStartingDigitThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: "1st-mail"
              type: mail
              subject: hi
              content: body
        """
        #expect(throws: NotificationParseError.invalidId(event: "SomeEvent", id: "1st-mail")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("id containing an illegal character throws invalidId")
    func idContainingIllegalCharacterThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: "some mail"
              type: mail
              subject: hi
              content: body
        """
        #expect(throws: NotificationParseError.invalidId(event: "SomeEvent", id: "some mail")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("duplicate id within the same event throws duplicateId")
    func duplicateIdThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: same-id
              type: mail
              subject: hi
              content: body
            - id: same-id
              type: inApp
              title: hi
              content: body
        """
        #expect(throws: NotificationParseError.duplicateId(event: "SomeEvent", id: "same-id")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("the same id may be reused across different events")
    func sameIdAcrossDifferentEventsIsAllowed() throws {
        let yaml = """
        EventA:
          notifications:
            - id: shared-id
              type: mail
              subject: hi
              content: body
        EventB:
          notifications:
            - id: shared-id
              type: mail
              subject: hi
              content: body
        """
        let definitions = try NotificationDefinitionParser.parse(yaml: yaml)
        #expect(definitions.count == 2)
        #expect(definitions.allSatisfy { $0.notifications[0].id == "shared-id" })
    }

    @Test("empty notifications list throws emptyNotifications")
    func emptyNotificationsThrows() {
        let yaml = """
        SomeEvent:
          notifications: []
        """
        #expect(throws: NotificationParseError.emptyNotifications(event: "SomeEvent")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("missing notifications key throws emptyNotifications")
    func missingNotificationsKeyThrows() {
        let yaml = """
        SomeEvent: {}
        """
        #expect(throws: NotificationParseError.emptyNotifications(event: "SomeEvent")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }
}

@Suite("Notification YAML render: parsing")
struct NotificationRenderParsingTests {

    @Test("mail entry defaults render to markdown when omitted")
    func mailDefaultsToMarkdown() throws {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-mail
              type: mail
              subject: hi
              content: body
        """
        let definitions = try NotificationDefinitionParser.parse(yaml: yaml)
        #expect(definitions[0].notifications[0].render == .markdown)
    }

    @Test("inApp entry defaults render to plaintext when omitted")
    func inAppDefaultsToPlaintext() throws {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-in-app
              type: inApp
              title: hi
              content: body
        """
        let definitions = try NotificationDefinitionParser.parse(yaml: yaml)
        #expect(definitions[0].notifications[0].render == .plaintext)
    }

    @Test("mail entry may explicitly declare render: plaintext")
    func mailExplicitPlaintext() throws {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-mail
              type: mail
              render: plaintext
              subject: hi
              content: body
        """
        let definitions = try NotificationDefinitionParser.parse(yaml: yaml)
        #expect(definitions[0].notifications[0].render == .plaintext)
    }

    @Test("inApp entry may explicitly declare render: markdown")
    func inAppExplicitMarkdown() throws {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-in-app
              type: inApp
              render: markdown
              title: hi
              content: body
        """
        let definitions = try NotificationDefinitionParser.parse(yaml: yaml)
        #expect(definitions[0].notifications[0].render == .markdown)
    }

    @Test("invalid render value throws invalidRenderFormat")
    func invalidRenderValueThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-mail
              type: mail
              render: html
              subject: hi
              content: body
        """
        #expect(throws: NotificationParseError.invalidRenderFormat(event: "SomeEvent", type: "mail", value: "html")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }
}

@Suite("PlaceholderExtractor")
struct PlaceholderExtractorTests {

    @Test("extracts placeholders in first-appearance order, deduplicated")
    func extractsOrderedDeduplicated() {
        let template = "你以「%QuotingCaseGroupCollaboratorRole%」角色被加入案件「%QuotingCaseGroupName%」，%CollaboratorDescription%。再次提及 %QuotingCaseGroupName%。"
        let placeholders = PlaceholderExtractor.placeholders(in: template)
        #expect(placeholders == ["QuotingCaseGroupCollaboratorRole", "QuotingCaseGroupName", "CollaboratorDescription"])
    }

    @Test("no placeholders returns empty array")
    func noPlaceholdersReturnsEmpty() {
        #expect(PlaceholderExtractor.placeholders(in: "plain text, no tokens here") == [])
    }

    @Test("adjacent tokens are both extracted")
    func adjacentTokensExtracted() {
        #expect(PlaceholderExtractor.placeholders(in: "%A%%B%") == ["A", "B"])
    }

    @Test("non-token percent signs are ignored")
    func nonTokenPercentSignsIgnored() {
        #expect(PlaceholderExtractor.placeholders(in: "50%% off %A% 100% sure") == ["A"])
    }
}
