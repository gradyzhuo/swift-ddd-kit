import Testing
import Foundation
import Yams
@testable import DomainEventGenerator

@Suite("Notification YAML Parsing")
struct NotificationParsingTests {

    // Spec §4 sample, verbatim.
    static let specSampleYAML = """
    CollaboratorAdded:
      recipients:
        - collaboratorId
      notifications:
        - type: mail
          subject: 你已被加入案件「%QuotingCaseGroupName%」
          content: |
            你以「%QuotingCaseGroupCollaboratorRole%」角色被加入案件「%QuotingCaseGroupName%」，%CollaboratorDescription%。
        - type: inApp
          title: 你已被加入案件「%QuotingCaseGroupName%」
          content: 你以「%QuotingCaseGroupCollaboratorRole%」角色被加入案件「%QuotingCaseGroupName%」。
    """

    @Test("spec §4 sample decodes: recipients, both notification types, exact fields")
    func specSampleDecodes() throws {
        let definitions = try NotificationDefinitionParser.parse(yaml: Self.specSampleYAML)
        #expect(definitions.count == 1)
        let definition = try #require(definitions.first)

        #expect(definition.eventName == "CollaboratorAdded")
        #expect(definition.recipients == ["collaboratorId"])
        #expect(definition.notifications.count == 2)

        let mail = definition.notifications[0]
        #expect(mail.type == "mail")
        #expect(mail.fields.map(\.name) == ["subject", "content"])
        #expect(mail.fields[0].template == "你已被加入案件「%QuotingCaseGroupName%」")
        #expect(mail.fields[1].template.contains("%QuotingCaseGroupCollaboratorRole%"))
        #expect(mail.fields[1].template.contains("%QuotingCaseGroupName%"))
        #expect(mail.fields[1].template.contains("%CollaboratorDescription%"))

        let inApp = definition.notifications[1]
        #expect(inApp.type == "inApp")
        #expect(inApp.fields.map(\.name) == ["title", "content"])
        #expect(inApp.fields[0].template == "你已被加入案件「%QuotingCaseGroupName%」")
        #expect(inApp.fields[1].template == "你以「%QuotingCaseGroupCollaboratorRole%」角色被加入案件「%QuotingCaseGroupName%」。")
    }

    @Test("unknown notification type throws unknownType")
    func unknownTypeThrows() {
        let yaml = """
        SomeEvent:
          recipients:
            - userId
          notifications:
            - type: push
              subject: hi
        """
        #expect(throws: NotificationParseError.unknownType(event: "SomeEvent", type: "push")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("mail entry missing content throws missingField")
    func missingFieldThrows() {
        let yaml = """
        SomeEvent:
          recipients:
            - userId
          notifications:
            - type: mail
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
          recipients:
            - userId
          notifications:
            - type: inApp
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
          recipients:
            - userId
          notifications:
            - type: mail
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
          recipients:
            - userId
          notifications:
            - type: inApp
              title: hi
              content: body
              icon: bell
        """
        #expect(throws: NotificationParseError.extraField(event: "SomeEvent", type: "inApp", field: "icon")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("empty recipients list throws emptyRecipients")
    func emptyRecipientsThrows() {
        let yaml = """
        SomeEvent:
          recipients: []
          notifications:
            - type: mail
              subject: hi
              content: body
        """
        #expect(throws: NotificationParseError.emptyRecipients(event: "SomeEvent")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("missing recipients key throws emptyRecipients")
    func missingRecipientsKeyThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - type: mail
              subject: hi
              content: body
        """
        #expect(throws: NotificationParseError.emptyRecipients(event: "SomeEvent")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("empty notifications list throws emptyNotifications")
    func emptyNotificationsThrows() {
        let yaml = """
        SomeEvent:
          recipients:
            - userId
          notifications: []
        """
        #expect(throws: NotificationParseError.emptyNotifications(event: "SomeEvent")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("missing notifications key throws emptyNotifications")
    func missingNotificationsKeyThrows() {
        let yaml = """
        SomeEvent:
          recipients:
            - userId
        """
        #expect(throws: NotificationParseError.emptyNotifications(event: "SomeEvent")) {
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
