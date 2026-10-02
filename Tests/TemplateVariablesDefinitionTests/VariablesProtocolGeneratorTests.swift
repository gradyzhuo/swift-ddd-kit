import Testing
@testable import TemplateVariablesDefinition

@Suite("VariablesProtocolGenerator")
struct VariablesProtocolGeneratorTests {

    static let variables: [VariableDefinition] = [
        // Declared in reverse of sorted order so the ordering assertions below discriminate.
        VariableDefinition(
            name: "MemberDescription",
            placeholder: "MemberDescription",
            inputs: [(name: "groupId", type: "String"), (name: "memberId", type: "String")]
        ),
        VariableDefinition(
            name: "GroupName",
            placeholder: "GroupName",
            inputs: [(name: "groupId", type: "String")]
        ),
    ]

    @Test("internal access level renders protocol, both signatures, dispatch seam")
    func rendersInternal() throws {
        let generator = VariablesProtocolGenerator(
            protocolName: "SampleVariables",
            variables: Self.variables
        )
        let output = generator.render(accessLevel: .internal).joined(separator: "\n")

        // protocol line + Sendable conformance
        #expect(output.contains("internal protocol SampleVariables: Sendable {"))

        // method signatures, sorted by variable name, exact parameter order preserved
        #expect(output.contains(
            "func memberDescription(groupId: String, memberId: String) async throws -> String"))
        #expect(output.contains(
            "func groupName(groupId: String) async throws -> String"))

        // signatures and dispatch cases are emitted in sorted order, not declaration order
        let groupSig = try #require(output.range(of: "func groupName("))
        let memberSig = try #require(output.range(of: "func memberDescription("))
        #expect(groupSig.lowerBound < memberSig.lowerBound)
        let groupCase = try #require(output.range(of: "case \"GroupName\":"))
        let memberCase = try #require(output.range(of: "case \"MemberDescription\":"))
        #expect(groupCase.lowerBound < memberCase.lowerBound)

        // VariablesRuntimeError emitted exactly once
        #expect(output.contains("enum VariablesRuntimeError: Error"))
        #expect(output.contains("case missingInput(placeholder: String, input: String)"))
        #expect(output.contains("case unknownPlaceholder(String)"))
        let occurrences = output.components(separatedBy: "enum VariablesRuntimeError").count - 1
        #expect(occurrences == 1)

        // dispatch seam: extension unmodified, access level on __value itself
        #expect(output.contains("extension SampleVariables {"))
        #expect(output.contains(
            "internal func __value(of placeholder: String, inputs: [String: String]) async throws -> String {"))
        #expect(output.contains("switch placeholder {"))

        // both placeholder cases present
        #expect(output.contains("case \"GroupName\":"))
        #expect(output.contains("case \"MemberDescription\":"))

        // missingInput guards for each input
        #expect(output.contains(
            """
            guard let groupId = inputs["groupId"] else { throw VariablesRuntimeError.missingInput(placeholder: "GroupName", input: "groupId") }
            """))
        #expect(output.contains(
            """
            guard let memberId = inputs["memberId"] else { throw VariablesRuntimeError.missingInput(placeholder: "MemberDescription", input: "memberId") }
            """))

        // resolving calls forward to the protocol methods, qualified with `self.` so a
        // same-named local `guard let` binding never shadows the method call (see
        // `callSiteDoesNotShadowLocalGuardLetBinding` below for the case that requires this)
        #expect(output.contains("return try await self.groupName(groupId: groupId)"))
        #expect(output.contains(
            "return try await self.memberDescription(groupId: groupId, memberId: memberId)"))

        // default case throws unknownPlaceholder
        #expect(output.contains("default: throw VariablesRuntimeError.unknownPlaceholder(placeholder)"))
    }

    @Test("public access level emits public protocol, __value, and runtime error")
    func rendersPublic() {
        let generator = VariablesProtocolGenerator(
            protocolName: "SampleVariables",
            variables: Self.variables
        )
        let output = generator.render(accessLevel: .public).joined(separator: "\n")

        #expect(output.contains("public protocol SampleVariables: Sendable {"))
        #expect(output.contains(
            "public func __value(of placeholder: String, inputs: [String: String]) async throws -> String {"))
        #expect(output.contains("public enum VariablesRuntimeError: Error"))
        // extension itself carries no access modifier regardless of accessLevel
        #expect(output.contains("extension SampleVariables {"))
        #expect(!output.contains("public extension SampleVariables"))
        #expect(!output.contains("internal extension SampleVariables"))
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
        #expect(output.contains("return try await self.staticGreeting()"))
    }

    @Test("call site does not shadow a local guard-let binding with the same name as the variable")
    func callSiteDoesNotShadowLocalGuardLetBinding() {
        // Regression for a real bug: when a variable's lowerCamelCased name equals its
        // sole input's name, the `guard let` above binds a local constant of that name,
        // which shadows the protocol method of the same name at an unqualified call site
        // — `groupId(groupId:)` resolves to the just-bound
        // `String`, not the method, and fails to compile ("cannot call value of
        // non-function type 'String'"). Qualifying with `self.` fixes it.
        let variables = [
            VariableDefinition(
                name: "GroupId",
                placeholder: "GroupId",
                inputs: [(name: "groupId", type: "String")]
            )
        ]
        let generator = VariablesProtocolGenerator(protocolName: "V", variables: variables)
        let output = generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(output.contains(
            "return try await self.groupId(groupId: groupId)"))
        #expect(!output.contains(
            "return try await groupId(groupId: groupId)"))
    }
}
