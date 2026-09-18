import Testing
@testable import DomainEventGenerator

@Suite("NotificationGenerator")
struct NotificationGeneratorTests {

    // Mirrors the spec §4 CollaboratorAdded sample: QuotingCaseGroupName appears in all three
    // of subject/content/title, QuotingCaseGroupCollaboratorRole appears in content twice,
    // CollaboratorDescription appears once.
    static let collaboratorAddedEvent = EventNotificationDefinition(
        eventName: "CollaboratorAdded",
        notifications: [
            NotificationEntry(type: "mail", render: .markdown, recipients: ["collaboratorId"], fields: [
                (name: "subject", template: "你已被加入案件「%QuotingCaseGroupName%」"),
                (name: "content", template: "你以「%QuotingCaseGroupCollaboratorRole%」角色被加入案件「%QuotingCaseGroupName%」，%CollaboratorDescription%。"),
            ]),
            NotificationEntry(type: "inApp", render: .markdown, recipients: ["collaboratorId"], fields: [
                (name: "title", template: "你已被加入案件「%QuotingCaseGroupName%」"),
                (name: "content", template: "你以「%QuotingCaseGroupCollaboratorRole%」角色被加入案件「%QuotingCaseGroupName%」。"),
            ]),
        ]
    )

    static let variables: [VariableDefinition] = [
        VariableDefinition(
            name: "QuotingCaseGroupName",
            placeholder: "QuotingCaseGroupName",
            inputs: [(name: "quotingCaseGroupingId", type: "String")]
        ),
        VariableDefinition(
            name: "QuotingCaseGroupCollaboratorRole",
            placeholder: "QuotingCaseGroupCollaboratorRole",
            inputs: [(name: "quotingCaseGroupingId", type: "String"), (name: "collaboratorId", type: "String")]
        ),
        VariableDefinition(
            name: "CollaboratorDescription",
            placeholder: "CollaboratorDescription",
            inputs: [(name: "quotingCaseGroupingId", type: "String"), (name: "collaboratorId", type: "String")]
        ),
    ]

    @Test("renders input struct with exactly the union properties, sorted by name")
    func rendersInputStruct() throws {
        let generator = NotificationGenerator(
            protocolName: "OpportunityNotificationVariables",
            events: [Self.collaboratorAddedEvent],
            variables: Self.variables
        )
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(output.contains("internal struct CollaboratorAddedNotificationInput: Decodable {"))
        #expect(output.contains("internal let collaboratorId: String"))
        #expect(output.contains("internal let quotingCaseGroupingId: String"))

        // exactly these two properties — no others (e.g. no stray "role" property)
        let letCount = output.components(separatedBy: "internal let ").count - 1
        #expect(letCount == 2)

        // public memberwise init, properties in the same sorted order as the stored properties
        #expect(output.contains("internal init(collaboratorId: String, quotingCaseGroupingId: String) {"))
        #expect(output.contains("self.collaboratorId = collaboratorId"))
        #expect(output.contains("self.quotingCaseGroupingId = quotingCaseGroupingId"))
    }

    @Test("each RenderedNotification embeds its own entry's recipients, in yaml order")
    func rendersRecipients() throws {
        let generator = NotificationGenerator(
            protocolName: "OpportunityNotificationVariables",
            events: [Self.collaboratorAddedEvent],
            variables: Self.variables
        )
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(!output.contains("static func recipients(input:"))
        #expect(output.contains(
            "RenderedNotification(\n                type: NotificationType(rawValue: \"mail\")!,\n                recipients: [input.collaboratorId],"))
        #expect(output.contains(
            "RenderedNotification(\n                type: NotificationType(rawValue: \"inApp\")!,\n                recipients: [input.collaboratorId],"))
    }

    @Test("each distinct placeholder is resolved exactly once despite repeated occurrences")
    func resolvesEachPlaceholderOnce() throws {
        let generator = NotificationGenerator(
            protocolName: "OpportunityNotificationVariables",
            events: [Self.collaboratorAddedEvent],
            variables: Self.variables
        )
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        // QuotingCaseGroupName appears in 3 templates (subject, mail content, title) but must be
        // resolved exactly once.
        let quotingCaseGroupNameResolution = "let quotingCaseGroupName = try await variables.__value(of: \"QuotingCaseGroupName\", inputs: inputs)"
        #expect(output.contains(quotingCaseGroupNameResolution))
        #expect(output.components(separatedBy: quotingCaseGroupNameResolution).count - 1 == 1)

        let roleResolution = "let quotingCaseGroupCollaboratorRole = try await variables.__value(of: \"QuotingCaseGroupCollaboratorRole\", inputs: inputs)"
        #expect(output.contains(roleResolution))
        #expect(output.components(separatedBy: roleResolution).count - 1 == 1)

        let descriptionResolution = "let collaboratorDescription = try await variables.__value(of: \"CollaboratorDescription\", inputs: inputs)"
        #expect(output.contains(descriptionResolution))
        #expect(output.components(separatedBy: descriptionResolution).count - 1 == 1)
    }

    @Test("render() builds inputs dictionary and substitutes templates")
    func rendersRenderBody() throws {
        let generator = NotificationGenerator(
            protocolName: "OpportunityNotificationVariables",
            events: [Self.collaboratorAddedEvent],
            variables: Self.variables
        )
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(output.contains("internal static func render(input: CollaboratorAddedNotificationInput, variables: some OpportunityNotificationVariables) async throws -> [RenderedNotification]"))
        #expect(output.contains("let inputs: [String: String] = ["))
        #expect(output.contains("\"collaboratorId\": input.collaboratorId,"))
        #expect(output.contains("\"quotingCaseGroupingId\": input.quotingCaseGroupingId,"))

        #expect(output.contains("RenderedNotification("))
        #expect(output.contains("type: NotificationType(rawValue: \"mail\")!,"))
        #expect(output.contains("type: NotificationType(rawValue: \"inApp\")!,"))
        #expect(output.contains("PlaceholderSubstitution.substitute("))
        #expect(output.contains("\"subject\":"))
        #expect(output.contains("\"content\":"))
        #expect(output.contains("\"title\":"))
    }

    @Test("undefinedPlaceholder throws when a template token has no matching variable")
    func undefinedPlaceholderThrows() {
        let event = EventNotificationDefinition(
            eventName: "SomeEvent",
            notifications: [
                NotificationEntry(type: "mail", render: .markdown, recipients: ["userId"], fields: [
                    (name: "subject", template: "Hi %Ghost%"),
                    (name: "content", template: "body"),
                ]),
            ]
        )
        let generator = NotificationGenerator(protocolName: "V", events: [event], variables: [])
        #expect(throws: NotificationGenerateError.undefinedPlaceholder(event: "SomeEvent", placeholder: "Ghost")) {
            _ = try generator.render(accessLevel: .internal)
        }
    }

    @Test("generated file imports NotificationDefinition")
    func importsNotificationDefinition() throws {
        let generator = NotificationGenerator(
            protocolName: "OpportunityNotificationVariables",
            events: [Self.collaboratorAddedEvent],
            variables: Self.variables
        )
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")
        #expect(output.contains("import NotificationDefinition"))
    }

    @Test("public access level emits public struct, enum, and functions")
    func publicAccessLevel() throws {
        let generator = NotificationGenerator(
            protocolName: "OpportunityNotificationVariables",
            events: [Self.collaboratorAddedEvent],
            variables: Self.variables
        )
        let output = try generator.render(accessLevel: .public).joined(separator: "\n")

        #expect(output.contains("public struct CollaboratorAddedNotificationInput: Decodable {"))
        #expect(output.contains("public enum CollaboratorAddedNotification {"))
        #expect(!output.contains("static func recipients(input:"))
        #expect(output.contains("public static func render(input: CollaboratorAddedNotificationInput, variables: some OpportunityNotificationVariables) async throws -> [RenderedNotification]"))
    }

    @Test("events are rendered sorted by name")
    func eventsSortedByName() throws {
        let eventB = EventNotificationDefinition(
            eventName: "BEvent",
            notifications: [NotificationEntry(type: "mail", render: .markdown, recipients: ["userId"], fields: [(name: "subject", template: "s"), (name: "content", template: "c")])]
        )
        let eventA = EventNotificationDefinition(
            eventName: "AEvent",
            notifications: [NotificationEntry(type: "mail", render: .markdown, recipients: ["userId"], fields: [(name: "subject", template: "s"), (name: "content", template: "c")])]
        )
        let generator = NotificationGenerator(protocolName: "V", events: [eventB, eventA], variables: [])
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        let aIndex = try #require(output.range(of: "AEventNotificationInput"))
        let bIndex = try #require(output.range(of: "BEventNotificationInput"))
        #expect(aIndex.lowerBound < bIndex.lowerBound)
    }

    @Test("unreferencedVariables reports a defined-but-unused variable")
    func unreferencedVariablesReported() {
        let unusedVariable = VariableDefinition(name: "UnusedVar", placeholder: "UnusedVar", inputs: [])
        let generator = NotificationGenerator(
            protocolName: "OpportunityNotificationVariables",
            events: [Self.collaboratorAddedEvent],
            variables: Self.variables + [unusedVariable]
        )
        #expect(generator.unreferencedVariables == ["UnusedVar"])
    }

    @Test("unreferencedVariables is empty when every variable is referenced")
    func unreferencedVariablesEmptyWhenAllUsed() {
        let generator = NotificationGenerator(
            protocolName: "OpportunityNotificationVariables",
            events: [Self.collaboratorAddedEvent],
            variables: Self.variables
        )
        #expect(generator.unreferencedVariables == [])
    }

    @Test("an event with zero referenced placeholders omits the unused `inputs` local")
    func emptyPlaceholdersOmitsInputsLocal() throws {
        let event = EventNotificationDefinition(
            eventName: "SomeEvent",
            notifications: [
                NotificationEntry(type: "mail", render: .markdown, recipients: ["userId"], fields: [
                    (name: "subject", template: "static subject"),
                    (name: "content", template: "static body, no placeholders"),
                ]),
            ]
        )
        let generator = NotificationGenerator(protocolName: "V", events: [event], variables: [])
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(!output.contains("let inputs:"))
        #expect(!output.contains("let values:"))
        #expect(output.contains("values: [:]"))
    }

    @Test("a placeholder that isn't a valid Swift identifier throws invalidIdentifier")
    func invalidPlaceholderThrows() {
        let event = EventNotificationDefinition(
            eventName: "SomeEvent",
            notifications: [
                NotificationEntry(type: "mail", render: .markdown, recipients: ["userId"], fields: [
                    (name: "subject", template: "Hi %123%"),
                    (name: "content", template: "body"),
                ]),
            ]
        )
        let generator = NotificationGenerator(protocolName: "V", events: [event], variables: [])
        #expect(throws: IdentifierValidationError.invalidIdentifier(kind: .placeholder, name: "123")) {
            _ = try generator.render(accessLevel: .internal)
        }
    }

    @Test("a placeholder that lowerCamels to a reserved local name (\"Inputs\" → \"inputs\") throws invalidIdentifier")
    func placeholderCollidingWithInputsLocalThrows() {
        let event = EventNotificationDefinition(
            eventName: "SomeEvent",
            notifications: [
                NotificationEntry(type: "mail", render: .markdown, recipients: ["userId"], fields: [
                    (name: "subject", template: "Hi %Inputs%"),
                    (name: "content", template: "body"),
                ]),
            ]
        )
        let generator = NotificationGenerator(protocolName: "V", events: [event], variables: [])
        #expect(throws: IdentifierValidationError.invalidIdentifier(kind: .placeholder, name: "Inputs")) {
            _ = try generator.render(accessLevel: .internal)
        }
    }

    @Test("two placeholders that lowerCamel to the same local name throw identifierCollision")
    func placeholderCollisionThrows() {
        let event = EventNotificationDefinition(
            eventName: "SomeEvent",
            notifications: [
                NotificationEntry(type: "mail", render: .markdown, recipients: ["userId"], fields: [
                    (name: "subject", template: "Hi %FooBar%"),
                    (name: "content", template: "Bye %fooBar%"),
                ]),
            ]
        )
        let variables: [VariableDefinition] = [
            VariableDefinition(name: "FooBar", placeholder: "FooBar", inputs: []),
            VariableDefinition(name: "fooBar", placeholder: "fooBar", inputs: []),
        ]
        let generator = NotificationGenerator(protocolName: "V", events: [event], variables: variables)
        #expect(throws: IdentifierValidationError.identifierCollision(a: "FooBar", b: "fooBar")) {
            _ = try generator.render(accessLevel: .internal)
        }
    }

    @Test("a template with quotes and backslashes emits a correctly escaped string literal")
    func escapesQuotesAndBackslashes() throws {
        let event = EventNotificationDefinition(
            eventName: "SomeEvent",
            notifications: [
                NotificationEntry(type: "mail", render: .markdown, recipients: ["userId"], fields: [
                    (name: "subject", template: #"He said "hi" and used \ backslash."#),
                    (name: "content", template: "body"),
                ]),
            ]
        )
        let generator = NotificationGenerator(protocolName: "V", events: [event], variables: [])
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        let expectedLine = #""subject": try PlaceholderSubstitution.substitute("He said \"hi\" and used \\ backslash.", values: [:]),"#
        #expect(output.contains(expectedLine))
    }

    @Test("markdown content field is rendered through MarkdownRendering.html with markdown escaping")
    func markdownContentUsesMarkdownRendering() throws {
        let event = EventNotificationDefinition(
            eventName: "SomeEvent",
            notifications: [
                NotificationEntry(type: "mail", render: .markdown, recipients: ["userId"], fields: [
                    (name: "subject", template: "s"),
                    (name: "content", template: "body"),
                ]),
            ]
        )
        let generator = NotificationGenerator(protocolName: "V", events: [event], variables: [])
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        let expectedLine = #""content": MarkdownRendering.html(from: try PlaceholderSubstitution.substitute("body", values: [:], escaping: .markdown)),"#
        #expect(output.contains(expectedLine))
    }

    @Test("plaintext content field skips MarkdownRendering and substitutes with no escaping")
    func plaintextContentSkipsMarkdownRendering() throws {
        let event = EventNotificationDefinition(
            eventName: "SomeEvent",
            notifications: [
                NotificationEntry(type: "inApp", render: .plaintext, recipients: ["userId"], fields: [
                    (name: "title", template: "t"),
                    (name: "content", template: "body"),
                ]),
            ]
        )
        let generator = NotificationGenerator(protocolName: "V", events: [event], variables: [])
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(!output.contains("MarkdownRendering"))
        let expectedLine = #""content": try PlaceholderSubstitution.substitute("body", values: [:]),"#
        #expect(output.contains(expectedLine))
    }

    @Test("inApp entry emits an inApp.render wire field with its resolved render value")
    func inAppEmitsRenderField() throws {
        let event = EventNotificationDefinition(
            eventName: "SomeEvent",
            notifications: [
                NotificationEntry(type: "inApp", render: .plaintext, recipients: ["userId"], fields: [
                    (name: "title", template: "t"),
                    (name: "content", template: "body"),
                ]),
            ]
        )
        let generator = NotificationGenerator(protocolName: "V", events: [event], variables: [])
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(output.contains(#""render": "plaintext","#))
    }

    @Test("mail entry never emits a render wire field")
    func mailNeverEmitsRenderField() throws {
        let event = EventNotificationDefinition(
            eventName: "SomeEvent",
            notifications: [
                NotificationEntry(type: "mail", render: .plaintext, recipients: ["userId"], fields: [
                    (name: "subject", template: "s"),
                    (name: "content", template: "body"),
                ]),
            ]
        )
        let generator = NotificationGenerator(protocolName: "V", events: [event], variables: [])
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(!output.contains(#""render":"#))
    }

    @Test("recipients live per notification-type entry, not per event")
    func recipientsPerEntry() throws {
        let yaml = """
        AssignedMemberAdded:
          notifications:
            - type: mail
              recipients:
                - departmentLeadId
              subject: s
              content: c
            - type: inApp
              recipients:
                - memberIds
              title: t
              content: c
        """
        let definitions = try NotificationDefinitionParser.parse(yaml: yaml)
        let event = try #require(definitions.first)
        #expect(event.notifications[0].recipients == ["departmentLeadId"])
        #expect(event.notifications[1].recipients == ["memberIds"])
    }

    @Test("an entry with empty recipients throws, naming that entry's type")
    func emptyRecipientsPerEntryThrows() throws {
        let yaml = """
        AssignedMemberAdded:
          notifications:
            - type: mail
              recipients: []
              subject: s
              content: c
        """
        #expect(throws: NotificationParseError.emptyRecipients(event: "AssignedMemberAdded", type: "mail")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("a missing recipients key on an entry throws the same emptyRecipients error")
    func missingRecipientsKeyThrows() throws {
        let yaml = """
        AssignedMemberAdded:
          notifications:
            - type: inApp
              title: t
              content: c
        """
        #expect(throws: NotificationParseError.emptyRecipients(event: "AssignedMemberAdded", type: "inApp")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("generated render() embeds each entry's own recipients, no standalone recipients(input:) function")
    func generatedRenderEmbedsPerEntryRecipients() throws {
        let events = try NotificationDefinitionParser.parse(yaml: """
        AssignedMemberAdded:
          notifications:
            - type: mail
              recipients:
                - departmentLeadId
              subject: s
              content: c
            - type: inApp
              recipients:
                - memberIds
              title: t
              content: c
        """)
        let generator = NotificationGenerator(protocolName: "V", events: events, variables: [])
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(output.contains(
            "RenderedNotification(\n                type: NotificationType(rawValue: \"mail\")!,\n                recipients: [input.departmentLeadId],"))
        #expect(output.contains(
            "RenderedNotification(\n                type: NotificationType(rawValue: \"inApp\")!,\n                recipients: [input.memberIds],"))
        #expect(!output.contains("static func recipients(input:"))
        #expect(output.contains("let departmentLeadId: String"))
        #expect(output.contains("let memberIds: String"))
    }

    @Test("existing all-plain-field recipients render exactly as before mixed-recipients support existed")
    func plainRecipientsRenderUnchanged() throws {
        // Regression guard for the Global Constraint: token-free entries must not change output.
        let generator = NotificationGenerator(
            protocolName: "OpportunityNotificationVariables",
            events: [Self.collaboratorAddedEvent],
            variables: Self.variables
        )
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(output.contains(
            "RenderedNotification(\n                type: NotificationType(rawValue: \"mail\")!,\n                recipients: [input.collaboratorId],"))
    }

    @Test("a %recipients:X% token generates an awaited variable call concatenated with plain fields")
    func mixedRecipientsGenerateAwaitedCall() throws {
        let event = EventNotificationDefinition(
            eventName: "AssignedMemberAdded",
            notifications: [
                NotificationEntry(
                    type: "mail", render: .markdown,
                    recipients: ["memberIds", .variable("AssignedDepartmentMembers")],
                    fields: [(name: "subject", template: "hi"), (name: "content", template: "hi")]
                ),
            ]
        )
        let variables = [
            VariableDefinition(
                name: "AssignedDepartmentMembers", placeholder: "AssignedDepartmentMembers",
                type: .recipients,
                inputs: [(name: "quotingCaseGroupingId", type: "String"), (name: "eventMetadata", type: "Data")]
            ),
        ]
        let generator = NotificationGenerator(
            protocolName: "OpportunityNotificationVariables", events: [event], variables: variables)
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(output.contains(
            "recipients: [input.memberIds] + (try await variables.assignedDepartmentMembers(quotingCaseGroupingId: input.quotingCaseGroupingId, eventMetadata: input.eventMetadata)),"))
        // eventMetadata must be typed Data on the generated Input struct, not String.
        #expect(output.contains("internal let eventMetadata: Data"))
        #expect(output.contains("internal let quotingCaseGroupingId: String"))
    }

    @Test("a recipients list with only a %recipients:X% token (no plain fields) still generates valid code")
    func tokenOnlyRecipientsGenerate() throws {
        let event = EventNotificationDefinition(
            eventName: "AssignedMemberAdded",
            notifications: [
                NotificationEntry(
                    type: "mail", render: .markdown,
                    recipients: [.variable("AssignedDepartmentMembers")],
                    fields: [(name: "subject", template: "hi"), (name: "content", template: "hi")]
                ),
            ]
        )
        let variables = [
            VariableDefinition(
                name: "AssignedDepartmentMembers", placeholder: "AssignedDepartmentMembers",
                type: .recipients,
                inputs: [(name: "quotingCaseGroupingId", type: "String")]
            ),
        ]
        let generator = NotificationGenerator(
            protocolName: "OpportunityNotificationVariables", events: [event], variables: variables)
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(output.contains(
            "recipients: [] + (try await variables.assignedDepartmentMembers(quotingCaseGroupingId: input.quotingCaseGroupingId)),"))
    }

    @Test("a %recipients:X% token naming an undeclared variable throws undefinedRecipientsVariable")
    func undefinedRecipientsVariableThrows() {
        let event = EventNotificationDefinition(
            eventName: "AssignedMemberAdded",
            notifications: [
                NotificationEntry(
                    type: "mail", render: .markdown,
                    recipients: [.variable("NoSuchVariable")],
                    fields: [(name: "subject", template: "hi"), (name: "content", template: "hi")]
                ),
            ]
        )
        let generator = NotificationGenerator(protocolName: "P", events: [event], variables: [])
        #expect(throws: NotificationGenerateError.undefinedRecipientsVariable(event: "AssignedMemberAdded", variable: "NoSuchVariable")) {
            _ = try generator.render(accessLevel: .internal)
        }
    }

    @Test("a %recipients:X% token naming a type: environment variable throws recipientsVariableWrongType")
    func recipientsTokenOnEnvironmentVariableThrows() {
        let event = EventNotificationDefinition(
            eventName: "AssignedMemberAdded",
            notifications: [
                NotificationEntry(
                    type: "mail", render: .markdown,
                    recipients: [.variable("QuotingCaseGroupName")],
                    fields: [(name: "subject", template: "hi"), (name: "content", template: "hi")]
                ),
            ]
        )
        let generator = NotificationGenerator(protocolName: "P", events: [event], variables: Self.variables)
        #expect(throws: NotificationGenerateError.recipientsVariableWrongType(event: "AssignedMemberAdded", variable: "QuotingCaseGroupName")) {
            _ = try generator.render(accessLevel: .internal)
        }
    }

    @Test("a type: recipients variable's placeholder used in a text template throws recipientsVariableUsedAsPlaceholder")
    func recipientsVariableUsedAsPlaceholderThrows() {
        let event = EventNotificationDefinition(
            eventName: "AssignedMemberAdded",
            notifications: [
                NotificationEntry(
                    type: "mail", render: .markdown,
                    recipients: ["memberIds"],
                    fields: [(name: "subject", template: "%AssignedDepartmentMembers%"), (name: "content", template: "hi")]
                ),
            ]
        )
        let variables = [
            VariableDefinition(
                name: "AssignedDepartmentMembers", placeholder: "AssignedDepartmentMembers",
                type: .recipients, inputs: []
            ),
        ]
        let generator = NotificationGenerator(protocolName: "P", events: [event], variables: variables)
        #expect(throws: NotificationGenerateError.recipientsVariableUsedAsPlaceholder(event: "AssignedMemberAdded", placeholder: "AssignedDepartmentMembers")) {
            _ = try generator.render(accessLevel: .internal)
        }
    }
}
