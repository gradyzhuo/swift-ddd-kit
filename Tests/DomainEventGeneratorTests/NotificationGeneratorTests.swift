import Testing
@testable import DomainEventGenerator

@Suite("NotificationGenerator")
struct NotificationGeneratorTests {

    // Mirrors the spec §4 CollaboratorAdded sample: QuotingCaseGroupName appears in all three
    // of subject/content/title, QuotingCaseGroupCollaboratorRole appears in content twice,
    // CollaboratorDescription appears once.
    static let collaboratorAddedEvent = EventNotificationDefinition(
        eventName: "CollaboratorAdded",
        recipients: ["collaboratorId"],
        notifications: [
            NotificationEntry(type: "mail", fields: [
                (name: "subject", template: "你已被加入案件「%QuotingCaseGroupName%」"),
                (name: "content", template: "你以「%QuotingCaseGroupCollaboratorRole%」角色被加入案件「%QuotingCaseGroupName%」，%CollaboratorDescription%。"),
            ]),
            NotificationEntry(type: "inApp", fields: [
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
    }

    @Test("recipients() returns the recipients fields' values in yaml order")
    func rendersRecipients() throws {
        let generator = NotificationGenerator(
            protocolName: "OpportunityNotificationVariables",
            events: [Self.collaboratorAddedEvent],
            variables: Self.variables
        )
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(output.contains("internal static func recipients(input: CollaboratorAddedNotificationInput) -> [String] {"))
        #expect(output.contains("[input.collaboratorId]"))
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
            recipients: ["userId"],
            notifications: [
                NotificationEntry(type: "mail", fields: [
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
        #expect(output.contains("public static func recipients(input: CollaboratorAddedNotificationInput) -> [String] {"))
        #expect(output.contains("public static func render(input: CollaboratorAddedNotificationInput, variables: some OpportunityNotificationVariables) async throws -> [RenderedNotification]"))
    }

    @Test("events are rendered sorted by name")
    func eventsSortedByName() throws {
        let eventB = EventNotificationDefinition(
            eventName: "BEvent",
            recipients: ["userId"],
            notifications: [NotificationEntry(type: "mail", fields: [(name: "subject", template: "s"), (name: "content", template: "c")])]
        )
        let eventA = EventNotificationDefinition(
            eventName: "AEvent",
            recipients: ["userId"],
            notifications: [NotificationEntry(type: "mail", fields: [(name: "subject", template: "s"), (name: "content", template: "c")])]
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
}
