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

    @Test("an input named after a Swift keyword throws invalidIdentifier")
    func reservedInputNameThrows() {
        let yaml = """
        QuotingCaseGroupName:
          placeholder: QuotingCaseGroupName
          inputs:
            - case: String
        """
        #expect(throws: IdentifierValidationError.invalidIdentifier(kind: .inputName, name: "case")) {
            _ = try VariablesParser.parse(yaml: yaml)
        }
    }

    @Test("type is optional and defaults to environment")
    func typeDefaultsToEnvironment() throws {
        let yaml = """
        QuotingCaseGroupName:
          placeholder: QuotingCaseGroupName
          inputs:
            - quotingCaseGroupingId: String
        """
        let variables = try VariablesParser.parse(yaml: yaml)
        #expect(variables[0].type == .environment)
    }

    @Test("type: recipients parses")
    func typeRecipientsParses() throws {
        let yaml = """
        AssignedDepartmentMembers:
          type: recipients
          placeholder: AssignedDepartmentMembers
          inputs:
            - quotingCaseGroupingId: String
        """
        let variables = try VariablesParser.parse(yaml: yaml)
        #expect(variables[0].type == .recipients)
    }

    @Test("unknown type value throws invalidType")
    func unknownTypeThrows() {
        let yaml = """
        SomeVariable:
          type: bogus
          placeholder: SomeVariable
        """
        #expect(throws: VariablesParseError.invalidType(variable: "SomeVariable", type: "bogus")) {
            _ = try VariablesParser.parse(yaml: yaml)
        }
    }

    @Test("$event.metadata parses as a bare reserved input with type Data")
    func eventMetadataParses() throws {
        let yaml = """
        AssignedDepartmentMembers:
          type: recipients
          placeholder: AssignedDepartmentMembers
          inputs:
            - quotingCaseGroupingId: String
            - $event.metadata
        """
        let variables = try VariablesParser.parse(yaml: yaml)
        #expect(variables[0].inputs.count == 2)
        #expect(variables[0].inputs[0].name == "quotingCaseGroupingId")
        #expect(variables[0].inputs[0].type == "String")
        #expect(variables[0].inputs[1].name == "eventMetadata")
        #expect(variables[0].inputs[1].type == "Data")
    }

    @Test("$event.metadata on a type: environment variable throws metadataOnNonRecipientsVariable")
    func eventMetadataOnEnvironmentThrows() {
        let yaml = """
        QuotingCaseGroupName:
          placeholder: QuotingCaseGroupName
          inputs:
            - quotingCaseGroupingId: String
            - $event.metadata
        """
        #expect(throws: VariablesParseError.metadataOnNonRecipientsVariable(variable: "QuotingCaseGroupName")) {
            _ = try VariablesParser.parse(yaml: yaml)
        }
    }

    @Test("$event.metadata with an explicit type suffix throws explicitMetadataType")
    func eventMetadataExplicitTypeThrows() {
        let yaml = """
        AssignedDepartmentMembers:
          type: recipients
          placeholder: AssignedDepartmentMembers
          inputs:
            - $event.metadata: Data
        """
        #expect(throws: VariablesParseError.explicitMetadataType(variable: "AssignedDepartmentMembers")) {
            _ = try VariablesParser.parse(yaml: yaml)
        }
    }

    @Test("a bare scalar input other than $event.metadata is still malformedInput")
    func otherBareScalarStillMalformed() {
        let yaml = """
        SomeVariable:
          placeholder: SomeVariable
          inputs:
            - justAName
        """
        #expect(throws: VariablesParseError.malformedInput(variable: "SomeVariable")) {
            _ = try VariablesParser.parse(yaml: yaml)
        }
    }
}
