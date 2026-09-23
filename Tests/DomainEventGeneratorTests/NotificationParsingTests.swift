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

    @Test("multiple entries of the same type are allowed as long as their ids are distinct")
    func multipleEntriesOfSameTypeAreAllowedWithDistinctIds() throws {
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
        let definitions = try NotificationDefinitionParser.parse(yaml: yaml)
        #expect(definitions[0].notifications.map(\.id) == ["first-mail", "second-mail"])
        #expect(definitions[0].notifications.allSatisfy { $0.type == "mail" })
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

    @Test("recipients: is optional and defaults to empty when absent")
    func recipientsDefaultsToEmpty() throws {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-mail
              type: mail
              subject: hi
              content: body
        """
        let definitions = try NotificationDefinitionParser.parse(yaml: yaml)
        #expect(definitions[0].notifications[0].recipients == [])
    }

    @Test("recipients: parses a list of field names, in declared order")
    func recipientsParsesFieldList() throws {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-mail
              type: mail
              recipients:
                - fieldA
                - fieldB
              subject: hi
              content: body
        """
        let definitions = try NotificationDefinitionParser.parse(yaml: yaml)
        #expect(definitions[0].notifications[0].recipients == ["fieldA", "fieldB"])
    }

    @Test("a recipients: field name that isn't a valid Swift identifier throws invalidIdentifier")
    func invalidRecipientFieldNameThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-mail
              type: mail
              recipients:
                - "%Foo%"
              subject: hi
              content: body
        """
        #expect(throws: IdentifierValidationError.invalidIdentifier(kind: .recipient, name: "%Foo%")) {
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

    @Test("mail entry accepts a scalar template: name with no slots")
    func mailScalarTemplateParses() throws {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-mail
              type: mail
              template: plain-notice
              subject: s
              content: c
        """
        let definitions = try NotificationDefinitionParser.parse(yaml: yaml)
        let entry = try #require(definitions.first?.notifications.first)
        let template = try #require(entry.template)
        #expect(template.name == "plain-notice")
        #expect(template.slots.isEmpty)
    }

    @Test("template: default is legal and parses like any other name")
    func mailTemplateDefaultParses() throws {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-mail
              type: mail
              template: default
              subject: s
              content: c
        """
        let entry = try #require(try NotificationDefinitionParser.parse(yaml: yaml).first?.notifications.first)
        #expect(entry.template?.name == "default")
    }

    @Test("template: is nil when the key is absent")
    func templateDefaultsToNil() throws {
        let entry = try #require(try NotificationDefinitionParser.parse(yaml: Self.specSampleYAML).first?.notifications.first)
        #expect(entry.template == nil)
    }

    @Test("inApp entry with template: throws templateNotSupported")
    func inAppTemplateThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-in-app
              type: inApp
              template: plain-notice
              title: t
              content: c
        """
        #expect(throws: NotificationParseError.templateNotSupported(event: "SomeEvent", id: "some-in-app")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("template name failing the id grammar throws invalidTemplateName")
    func invalidTemplateNameThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-mail
              type: mail
              template: ../Evil
              subject: s
              content: c
        """
        #expect(throws: NotificationParseError.invalidTemplateName(event: "SomeEvent", id: "some-mail", value: "../Evil")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("template: as a sequence throws invalidTemplate")
    func templateSequenceThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-mail
              type: mail
              template: [a, b]
              subject: s
              content: c
        """
        #expect(throws: NotificationParseError.invalidTemplate(event: "SomeEvent", id: "some-mail")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("mail entry accepts template: { name, slots } and preserves slot order")
    func mailMappingTemplateParses() throws {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-mail
              type: mail
              template:
                name: one-button
                slots:
                  action_label: 前往查看
                  action_url: https://example.test/cases/%CaseId%
              subject: s
              content: c
        """
        let entry = try #require(try NotificationDefinitionParser.parse(yaml: yaml).first?.notifications.first)
        let template = try #require(entry.template)
        #expect(template.name == "one-button")
        #expect(template.slots.map(\.name) == ["action_label", "action_url"])
        #expect(template.slots[0].template == "前往查看")
        #expect(template.slots[1].template == "https://example.test/cases/%CaseId%")
    }

    @Test("template mapping without slots parses with empty slots")
    func mappingWithoutSlotsParses() throws {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-mail
              type: mail
              template:
                name: plain-notice
              subject: s
              content: c
        """
        let entry = try #require(try NotificationDefinitionParser.parse(yaml: yaml).first?.notifications.first)
        #expect(entry.template?.name == "plain-notice")
        #expect(entry.template?.slots.isEmpty == true)
    }

    @Test("template mapping without name throws templateMissingName")
    func mappingMissingNameThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-mail
              type: mail
              template:
                slots:
                  action_url: https://example.test
              subject: s
              content: c
        """
        #expect(throws: NotificationParseError.templateMissingName(event: "SomeEvent", id: "some-mail")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("template mapping with an unknown key throws templateExtraField")
    func mappingExtraKeyThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-mail
              type: mail
              template:
                name: one-button
                variables:
                  x: y
              subject: s
              content: c
        """
        #expect(throws: NotificationParseError.templateExtraField(event: "SomeEvent", id: "some-mail", field: "variables")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("slot name with uppercase or hyphen throws invalidSlotName")
    func invalidSlotNameThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-mail
              type: mail
              template:
                name: one-button
                slots:
                  action-url: https://example.test
              subject: s
              content: c
        """
        #expect(throws: NotificationParseError.invalidSlotName(event: "SomeEvent", id: "some-mail", slot: "action-url")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("a reserved built-in token used as a slot name throws invalidSlotName")
    func reservedSlotNameThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-mail
              type: mail
              template:
                name: one-button
                slots:
                  content: overwrite
              subject: s
              content: c
        """
        #expect(throws: NotificationParseError.invalidSlotName(event: "SomeEvent", id: "some-mail", slot: "content")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("a slot whose value is not a scalar string throws invalidSlotValue")
    func nonScalarSlotValueThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-mail
              type: mail
              template:
                name: one-button
                slots:
                  action_url:
                    nested: true
              subject: s
              content: c
        """
        #expect(throws: NotificationParseError.invalidSlotValue(event: "SomeEvent", id: "some-mail", slot: "action_url")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("a null slot value (~) throws invalidSlotValue")
    func nullSlotValueThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-mail
              type: mail
              template:
                name: one-button
                slots:
                  action_label: ~
              subject: s
              content: c
        """
        #expect(throws: NotificationParseError.invalidSlotValue(event: "SomeEvent", id: "some-mail", slot: "action_label")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("an empty slot value throws invalidSlotValue")
    func emptySlotValueThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-mail
              type: mail
              template:
                name: one-button
                slots:
                  action_url:
              subject: s
              content: c
        """
        #expect(throws: NotificationParseError.invalidSlotValue(event: "SomeEvent", id: "some-mail", slot: "action_url")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("a numeric or boolean slot value is accepted as its text, like subject")
    func scalarSlotValuesAreCoercedToText() throws {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-mail
              type: mail
              template:
                name: one-button
                slots:
                  count: 123
                  flag: true
              subject: s
              content: c
        """
        let entry = try #require(try NotificationDefinitionParser.parse(yaml: yaml).first?.notifications.first)
        #expect(entry.template?.slots.map(\.template) == ["123", "true"])
    }

    @Test("template: with a null value throws invalidTemplate")
    func nullTemplateThrows() {
        for value in ["~", ""] {
            let yaml = """
            SomeEvent:
              notifications:
                - id: some-mail
                  type: mail
                  template: \(value)
                  subject: s
                  content: c
            """
            #expect(throws: NotificationParseError.invalidTemplate(event: "SomeEvent", id: "some-mail")) {
                _ = try NotificationDefinitionParser.parse(yaml: yaml)
            }
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
