import Testing
import Foundation
@testable import DomainEventGenerator

@Suite("Variables YAML Parsing")
struct VariablesParsingTests {

    @Test("happy path decodes two variables with ordered inputs preserved")
    func happyPathDecodes() throws {
        let yaml = """
        QuotingCaseGroupName:
          placeholder: QuotingCaseGroupName
          inputs:
            - quotingCaseGroupingId: String

        CollaboratorDescription:
          placeholder: CollaboratorDescription
          inputs:
            - quotingCaseGroupingId: String
            - collaboratorId: String
        """
        let variables = try VariablesParser.parse(yaml: yaml)
        #expect(variables.count == 2)

        let quotingCaseGroupName = try #require(variables.first { $0.name == "QuotingCaseGroupName" })
        #expect(quotingCaseGroupName.placeholder == "QuotingCaseGroupName")
        #expect(quotingCaseGroupName.inputs.count == 1)
        #expect(quotingCaseGroupName.inputs[0].name == "quotingCaseGroupingId")
        #expect(quotingCaseGroupName.inputs[0].type == "String")

        let collaboratorDescription = try #require(variables.first { $0.name == "CollaboratorDescription" })
        #expect(collaboratorDescription.placeholder == "CollaboratorDescription")
        #expect(collaboratorDescription.inputs.count == 2)
        // order must be preserved exactly as declared in the YAML
        #expect(collaboratorDescription.inputs[0].name == "quotingCaseGroupingId")
        #expect(collaboratorDescription.inputs[0].type == "String")
        #expect(collaboratorDescription.inputs[1].name == "collaboratorId")
        #expect(collaboratorDescription.inputs[1].type == "String")
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
        QuotingCaseGroupName:
          inputs:
            - quotingCaseGroupingId: String
        """
        #expect(throws: VariablesParseError.missingPlaceholder(variable: "QuotingCaseGroupName")) {
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
        QuotingCaseGroupName:
          placeholder: QuotingCaseGroupName
          inputs:
            - quotingCaseGroupingId: String
              collaboratorId: String
        """
        #expect(throws: VariablesParseError.malformedInput(variable: "QuotingCaseGroupName")) {
            _ = try VariablesParser.parse(yaml: yaml)
        }
    }

    @Test("inputs entry with zero keys throws malformedInput")
    func malformedInputWithZeroKeysThrows() {
        let yaml = """
        QuotingCaseGroupName:
          placeholder: QuotingCaseGroupName
          inputs:
            - {}
        """
        #expect(throws: VariablesParseError.malformedInput(variable: "QuotingCaseGroupName")) {
            _ = try VariablesParser.parse(yaml: yaml)
        }
    }

    @Test("unsupported input type throws unsupportedInputType")
    func unsupportedInputTypeThrows() {
        let yaml = """
        QuotingCaseGroupName:
          placeholder: QuotingCaseGroupName
          inputs:
            - quotingCaseGroupingId: Int
        """
        #expect(throws: VariablesParseError.unsupportedInputType(
            variable: "QuotingCaseGroupName", input: "quotingCaseGroupingId", type: "Int")) {
            _ = try VariablesParser.parse(yaml: yaml)
        }
    }
}
