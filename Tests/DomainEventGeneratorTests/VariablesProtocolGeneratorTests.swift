import Testing
@testable import DomainEventGenerator

@Suite("VariablesProtocolGenerator")
struct VariablesProtocolGeneratorTests {

    static let variables: [VariableDefinition] = [
        VariableDefinition(
            name: "QuotingCaseGroupName",
            placeholder: "QuotingCaseGroupName",
            inputs: [(name: "quotingCaseGroupingId", type: "String")]
        ),
        VariableDefinition(
            name: "CollaboratorDescription",
            placeholder: "CollaboratorDescription",
            inputs: [(name: "quotingCaseGroupingId", type: "String"), (name: "collaboratorId", type: "String")]
        ),
    ]

    @Test("internal access level renders protocol, both signatures, dispatch seam")
    func rendersInternal() {
        let generator = VariablesProtocolGenerator(
            protocolName: "OpportunityNotificationVariables",
            variables: Self.variables
        )
        let output = generator.render(accessLevel: .internal).joined(separator: "\n")

        // protocol line + Sendable conformance
        #expect(output.contains("internal protocol OpportunityNotificationVariables: Sendable {"))

        // method signatures, sorted by variable name, exact parameter order preserved
        #expect(output.contains(
            "func collaboratorDescription(quotingCaseGroupingId: String, collaboratorId: String) async throws -> String"))
        #expect(output.contains(
            "func quotingCaseGroupName(quotingCaseGroupingId: String) async throws -> String"))

        // VariablesRuntimeError emitted exactly once
        #expect(output.contains("enum VariablesRuntimeError: Error"))
        #expect(output.contains("case missingInput(placeholder: String, input: String)"))
        #expect(output.contains("case unknownPlaceholder(String)"))
        let occurrences = output.components(separatedBy: "enum VariablesRuntimeError").count - 1
        #expect(occurrences == 1)

        // dispatch seam: extension unmodified, access level on __value itself
        #expect(output.contains("extension OpportunityNotificationVariables {"))
        #expect(output.contains(
            "internal func __value(of placeholder: String, inputs: [String: String]) async throws -> String {"))
        #expect(output.contains("switch placeholder {"))

        // both placeholder cases present
        #expect(output.contains("case \"QuotingCaseGroupName\":"))
        #expect(output.contains("case \"CollaboratorDescription\":"))

        // missingInput guards for each input
        #expect(output.contains(
            """
            guard let quotingCaseGroupingId = inputs["quotingCaseGroupingId"] else { throw VariablesRuntimeError.missingInput(placeholder: "QuotingCaseGroupName", input: "quotingCaseGroupingId") }
            """))
        #expect(output.contains(
            """
            guard let collaboratorId = inputs["collaboratorId"] else { throw VariablesRuntimeError.missingInput(placeholder: "CollaboratorDescription", input: "collaboratorId") }
            """))

        // resolving calls forward to the protocol methods
        #expect(output.contains("return try await quotingCaseGroupName(quotingCaseGroupingId: quotingCaseGroupingId)"))
        #expect(output.contains(
            "return try await collaboratorDescription(quotingCaseGroupingId: quotingCaseGroupingId, collaboratorId: collaboratorId)"))

        // default case throws unknownPlaceholder
        #expect(output.contains("default: throw VariablesRuntimeError.unknownPlaceholder(placeholder)"))
    }

    @Test("public access level emits public protocol, __value, and runtime error")
    func rendersPublic() {
        let generator = VariablesProtocolGenerator(
            protocolName: "OpportunityNotificationVariables",
            variables: Self.variables
        )
        let output = generator.render(accessLevel: .public).joined(separator: "\n")

        #expect(output.contains("public protocol OpportunityNotificationVariables: Sendable {"))
        #expect(output.contains(
            "public func __value(of placeholder: String, inputs: [String: String]) async throws -> String {"))
        #expect(output.contains("public enum VariablesRuntimeError: Error"))
        // extension itself carries no access modifier regardless of accessLevel
        #expect(output.contains("extension OpportunityNotificationVariables {"))
        #expect(!output.contains("public extension OpportunityNotificationVariables"))
        #expect(!output.contains("internal extension OpportunityNotificationVariables"))
    }

    @Test("variable with no inputs renders a zero-parameter method and zero-guard dispatch case")
    func variableWithNoInputs() {
        let variables = [
            VariableDefinition(name: "StaticGreeting", placeholder: "StaticGreeting", inputs: [])
        ]
        let generator = VariablesProtocolGenerator(protocolName: "V", variables: variables)
        let output = generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(output.contains("func staticGreeting() async throws -> String"))
        #expect(output.contains("case \"StaticGreeting\":"))
        #expect(output.contains("return try await staticGreeting()"))
    }
}
