import Testing
@testable import DomainEventGenerator

@Suite("NotificationGenerator")
struct NotificationGeneratorTests {

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

    static let collaboratorAddedEvent = EventNotificationDefinition(
        eventName: "CollaboratorAdded",
        notifications: [
            NotificationEntry(
                id: "collaborator-added-mail", type: "mail", render: .markdown,
                fields: [
                    (name: "subject", template: "你已被加入案件「%QuotingCaseGroupName%」"),
                    (name: "content", template: "你以「%QuotingCaseGroupCollaboratorRole%」角色被加入案件「%QuotingCaseGroupName%」，%CollaboratorDescription%。"),
                ]),
            NotificationEntry(
                id: "collaborator-added-in-app", type: "inApp", render: .markdown,
                fields: [
                    (name: "title", template: "你已被加入案件「%QuotingCaseGroupName%」"),
                    (name: "content", template: "你以「%QuotingCaseGroupCollaboratorRole%」角色被加入案件「%QuotingCaseGroupName%」。"),
                ]),
        ]
    )

    @Test("emits import DDDCore, Foundation, NotificationDefinition")
    func emitsRequiredImports() throws {
        let generator = NotificationGenerator(
            protocolName: "OpportunityNotificationVariables",
            events: [Self.collaboratorAddedEvent],
            variables: Self.variables
        )
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")
        #expect(output.contains("import DDDCore"))
        #expect(output.contains("import Foundation"))
        #expect(output.contains("import NotificationDefinition"))
    }

    @Test("generates one protocol per entry, named <EventName>Notification<IdPascal>Protocol")
    func protocolNamedFromEventAndId() throws {
        let generator = NotificationGenerator(
            protocolName: "OpportunityNotificationVariables",
            events: [Self.collaboratorAddedEvent],
            variables: Self.variables
        )
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(output.contains("internal protocol CollaboratorAddedNotificationCollaborator_Added_MailProtocol: Sendable {"))
        #expect(output.contains("internal protocol CollaboratorAddedNotificationCollaborator_Added_In_AppProtocol: Sendable {"))
    }

    @Test("id → PascalCase: single segment, and mixed - / _ separators")
    func idPascalCaseTransform() throws {
        let event = EventNotificationDefinition(
            eventName: "Foo",
            notifications: [
                NotificationEntry(id: "mail", type: "mail", render: .markdown, fields: [(name: "subject", template: "hi"), (name: "content", template: "hi")]),
            ])
        let generator = NotificationGenerator(protocolName: "P", events: [event], variables: [])
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")
        #expect(output.contains("protocol FooNotificationMailProtocol: Sendable {"))

        let event2 = EventNotificationDefinition(
            eventName: "Foo",
            notifications: [
                NotificationEntry(id: "test_abc-mail", type: "mail", render: .markdown, fields: [(name: "subject", template: "hi"), (name: "content", template: "hi")]),
            ])
        let generator2 = NotificationGenerator(protocolName: "P", events: [event2], variables: [])
        let output2 = try generator2.render(accessLevel: .internal).joined(separator: "\n")
        #expect(output2.contains("protocol FooNotificationTest_Abc_MailProtocol: Sendable {"))
    }

    @Test("protocol declares associatedtype DomainEventType, var event, known fields, recipients() and render() requirements")
    func protocolDeclaresAllRequirements() throws {
        let generator = NotificationGenerator(
            protocolName: "OpportunityNotificationVariables",
            events: [Self.collaboratorAddedEvent],
            variables: Self.variables
        )
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(output.contains("internal protocol CollaboratorAddedNotificationCollaborator_Added_MailProtocol: Sendable {\n    associatedtype DomainEventType: DomainEvent\n    var event: DomainEventType { get }"))
        // known fields: union of QuotingCaseGroupName/QuotingCaseGroupCollaboratorRole/CollaboratorDescription's
        // inputs, referenced by the mail entry's own subject/content templates.
        #expect(output.contains("var collaboratorId: String { get }"))
        #expect(output.contains("var quotingCaseGroupingId: String { get }"))
        #expect(output.contains("func recipients() async throws -> [String]"))
        #expect(output.contains("func render(variables: some OpportunityNotificationVariables) async throws -> RenderedNotification"))
    }

    @Test("known-field properties are derived per entry, not shared across the event's other entries")
    func knownFieldsArePerEntry() throws {
        // mail's content uses CollaboratorDescription (needs collaboratorId); inApp's content
        // does not — so inApp's protocol must NOT declare a collaboratorId property, even though
        // it's declared for mail (same event).
        let event = EventNotificationDefinition(
            eventName: "CollaboratorAdded",
            notifications: [
                NotificationEntry(
                    id: "mail-with-description", type: "mail", render: .markdown,
                    fields: [
                        (name: "subject", template: "hi"),
                        (name: "content", template: "%CollaboratorDescription%"),
                    ]),
                NotificationEntry(
                    id: "in-app-plain", type: "inApp", render: .plaintext,
                    fields: [
                        (name: "title", template: "hi"),
                        (name: "content", template: "%QuotingCaseGroupName%"),
                    ]),
            ])
        let generator = NotificationGenerator(protocolName: "P", events: [event], variables: Self.variables)
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        let mailProtocolStart = try #require(output.range(of: "protocol CollaboratorAddedNotificationMail_With_DescriptionProtocol"))
        let inAppProtocolStart = try #require(output.range(of: "protocol CollaboratorAddedNotificationIn_App_PlainProtocol"))
        let mailBlock = String(output[mailProtocolStart.lowerBound..<inAppProtocolStart.lowerBound])

        #expect(mailBlock.contains("var collaboratorId: String { get }"))
        #expect(mailBlock.contains("var quotingCaseGroupingId: String { get }"))

        let inAppBlock = String(output[inAppProtocolStart.lowerBound...])
        #expect(!inAppBlock.contains("var collaboratorId: String { get }"))
        #expect(inAppBlock.contains("var quotingCaseGroupingId: String { get }"))
    }

    @Test("an entry with no placeholders has no known-field properties and no inputs/values dicts")
    func entryWithNoPlaceholdersHasNoKnownFields() throws {
        let event = EventNotificationDefinition(
            eventName: "Foo",
            notifications: [
                NotificationEntry(id: "static-mail", type: "mail", render: .plaintext, fields: [(name: "subject", template: "hi"), (name: "content", template: "static text, no tokens")]),
            ])
        let generator = NotificationGenerator(protocolName: "P", events: [event], variables: [])
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        // Exactly one " { get }" in the whole output — the fixed `var event: DomainEventType { get }`
        // — proves no known-field property line was added.
        #expect(output.components(separatedBy: "{ get }").count - 1 == 1)
        #expect(!output.contains("let inputs: [String: String] = ["))
        #expect(!output.contains("let values: [String: String] = ["))
    }

    @Test("default render() extension resolves placeholders and calls self.recipients()")
    func defaultRenderCallsRecipientsAndSubstitutes() throws {
        let event = EventNotificationDefinition(
            eventName: "Foo",
            notifications: [
                NotificationEntry(id: "mail", type: "mail", render: .markdown, fields: [(name: "subject", template: "hi %QuotingCaseGroupName%"), (name: "content", template: "body")]),
            ])
        let generator = NotificationGenerator(protocolName: "P", events: [event], variables: [Self.variables[0]])
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(output.contains("extension FooNotificationMailProtocol {"))
        #expect(output.contains("let inputs: [String: String] = ["))
        #expect(output.contains("\"quotingCaseGroupingId\": quotingCaseGroupingId,"))
        #expect(output.contains("let quotingCaseGroupName = try await variables.__value(of: \"QuotingCaseGroupName\", inputs: inputs)"))
        #expect(output.contains("recipients: try await self.recipients(),"))
        #expect(output.contains("type: NotificationType(rawValue: \"mail\")!,"))
    }

    @Test("inApp entries carry the render wire field, mail entries do not")
    func inAppCarriesRenderField() throws {
        let generator = NotificationGenerator(
            protocolName: "OpportunityNotificationVariables",
            events: [Self.collaboratorAddedEvent],
            variables: Self.variables
        )
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        let mailStart = try #require(output.range(of: "extension CollaboratorAddedNotificationCollaborator_Added_MailProtocol"))
        let inAppStart = try #require(output.range(of: "extension CollaboratorAddedNotificationCollaborator_Added_In_AppProtocol"))
        let mailBlock = String(output[mailStart.lowerBound..<inAppStart.lowerBound])
        let inAppBlock = String(output[inAppStart.lowerBound...])

        #expect(!mailBlock.contains("\"render\":"))
        #expect(inAppBlock.contains("\"render\": \"markdown\","))
    }

    @Test("markdown content is rendered via MarkdownRendering.html, plaintext content is not")
    func markdownVsPlaintextContentRendering() throws {
        let event = EventNotificationDefinition(
            eventName: "Foo",
            notifications: [
                NotificationEntry(id: "md-mail", type: "mail", render: .markdown, fields: [(name: "subject", template: "hi"), (name: "content", template: "body")]),
                NotificationEntry(id: "plain-in-app", type: "inApp", render: .plaintext, fields: [(name: "title", template: "hi"), (name: "content", template: "body")]),
            ])
        let generator = NotificationGenerator(protocolName: "P", events: [event], variables: [])
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(output.contains("\"content\": MarkdownRendering.html(from: try PlaceholderSubstitution.substitute(\"body\", values: [:], escaping: .markdown)),"))
        #expect(output.contains("\"content\": try PlaceholderSubstitution.substitute(\"body\", values: [:]),"))
    }

    @Test("undefined placeholder throws undefinedPlaceholder")
    func undefinedPlaceholderThrows() {
        let event = EventNotificationDefinition(
            eventName: "Foo",
            notifications: [
                NotificationEntry(id: "mail", type: "mail", render: .markdown, fields: [(name: "subject", template: "%NoSuchVariable%"), (name: "content", template: "hi")]),
            ])
        let generator = NotificationGenerator(protocolName: "P", events: [event], variables: [])
        #expect(throws: NotificationGenerateError.undefinedPlaceholder(event: "Foo", placeholder: "NoSuchVariable")) {
            _ = try generator.render(accessLevel: .internal)
        }
    }

    @Test("two ids producing the same generated protocol name throw duplicateGeneratedProtocolName")
    func duplicateGeneratedProtocolNameThrows() {
        let event = EventNotificationDefinition(
            eventName: "Foo",
            notifications: [
                NotificationEntry(id: "test-abc", type: "mail", render: .markdown, fields: [(name: "subject", template: "hi"), (name: "content", template: "hi")]),
                NotificationEntry(id: "test_abc", type: "inApp", render: .markdown, fields: [(name: "title", template: "hi"), (name: "content", template: "hi")]),
            ])
        let generator = NotificationGenerator(protocolName: "P", events: [event], variables: [])
        #expect(throws: NotificationGenerateError.duplicateGeneratedProtocolName(event: "Foo", a: "test-abc", b: "test_abc")) {
            _ = try generator.render(accessLevel: .internal)
        }
    }

    @Test("unreferencedVariables still reports a variable no entry's templates reference")
    func unreferencedVariablesUnaffected() {
        let generator = NotificationGenerator(
            protocolName: "OpportunityNotificationVariables",
            events: [Self.collaboratorAddedEvent],
            variables: Self.variables + [
                VariableDefinition(name: "NeverUsed", placeholder: "NeverUsed", inputs: []),
            ]
        )
        #expect(generator.unreferencedVariables == ["NeverUsed"])
    }
}
