import Testing
import Foundation
@testable import TemplateVariablesDefinition

@Suite("Variables YAML Parsing")
struct VariablesParsingTests {

    @Test("happy path decodes two variables with ordered inputs preserved")
    func happyPathDecodes() throws {
        let yaml = """
        GroupName:
          placeholder: GroupName
          inputs:
            - groupId: String

        MemberDescription:
          placeholder: MemberDescription
          inputs:
            - groupId: String
            - memberId: String
        """
        let variables = try VariablesParser.parse(yaml: yaml)
        #expect(variables.count == 2)

        let groupName = try #require(variables.first { $0.name == "GroupName" })
        #expect(groupName.placeholder == "GroupName")
        #expect(groupName.inputs.count == 1)
        #expect(groupName.inputs[0].name == "groupId")
        #expect(groupName.inputs[0].type == "String")

        let memberDescription = try #require(variables.first { $0.name == "MemberDescription" })
        #expect(memberDescription.placeholder == "MemberDescription")
        #expect(memberDescription.inputs.count == 2)
        // order must be preserved exactly as declared in the YAML
        #expect(memberDescription.inputs[0].name == "groupId")
        #expect(memberDescription.inputs[0].type == "String")
        #expect(memberDescription.inputs[1].name == "memberId")
        #expect(memberDescription.inputs[1].type == "String")
    }

    @Test("variable without an inputs list decodes with zero inputs")
    func missingInputsListIsEmpty() throws {
        let yaml = """
        NoInputsVariable:
          placeholder: NoInputsVariable
        """
        let variables = try VariablesParser.parse(yaml: yaml)
        let variable = try #require(variables.first { $0.name == "NoInputsVariable" })
        #expect(variable.inputs.isEmpty)
    }

    @Test("missing placeholder throws missingPlaceholder")
    func missingPlaceholderThrows() {
        let yaml = """
        GroupName:
          inputs:
            - groupId: String
        """
        #expect(throws: VariablesParseError.missingPlaceholder(variable: "GroupName")) {
            _ = try VariablesParser.parse(yaml: yaml)
        }
    }

    @Test("duplicate placeholder across variables throws duplicatePlaceholder")
    func duplicatePlaceholderThrows() {
        let yaml = """
        VariableA:
          placeholder: SameToken
          inputs:
            - a: String

        VariableB:
          placeholder: SameToken
          inputs:
            - b: String
        """
        #expect(throws: VariablesParseError.duplicatePlaceholder(placeholder: "SameToken")) {
            _ = try VariablesParser.parse(yaml: yaml)
        }
    }

    @Test("inputs entry with two keys throws malformedInput")
    func malformedInputWithTwoKeysThrows() {
        let yaml = """
        GroupName:
          placeholder: GroupName
          inputs:
            - groupId: String
              memberId: String
        """
        #expect(throws: VariablesParseError.malformedInput(variable: "GroupName")) {
            _ = try VariablesParser.parse(yaml: yaml)
        }
    }

    @Test("inputs entry with zero keys throws malformedInput")
    func malformedInputWithZeroKeysThrows() {
        let yaml = """
        GroupName:
          placeholder: GroupName
          inputs:
            - {}
        """
        #expect(throws: VariablesParseError.malformedInput(variable: "GroupName")) {
            _ = try VariablesParser.parse(yaml: yaml)
        }
    }

    @Test("unsupported input type throws unsupportedInputType")
    func unsupportedInputTypeThrows() {
        let yaml = """
        GroupName:
          placeholder: GroupName
          inputs:
            - groupId: Int
        """
        #expect(throws: VariablesParseError.unsupportedInputType(
            variable: "GroupName", input: "groupId", type: "Int")) {
            _ = try VariablesParser.parse(yaml: yaml)
        }
    }

    @Test("an input named after a Swift keyword throws invalidIdentifier")
    func reservedInputNameThrows() {
        let yaml = """
        GroupName:
          placeholder: GroupName
          inputs:
            - case: String
        """
        #expect(throws: IdentifierValidationError.invalidIdentifier(kind: .inputName, name: "case")) {
            _ = try VariablesParser.parse(yaml: yaml)
        }
    }
}
