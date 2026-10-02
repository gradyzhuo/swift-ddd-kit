import Testing
@testable import TemplateVariablesDefinition

@Suite("IdentifierValidation")
struct IdentifierValidationTests {

    @Test("a variable lowerCamel-ing to `inputs` is rejected — it would shadow the dispatch seam's parameter")
    func inputsIsReservedForVariableNames() {
        #expect(throws: IdentifierValidationError.invalidIdentifier(kind: .variableName, name: "Inputs")) {
            try IdentifierValidation.validateLowerCamel("Inputs", kind: .variableName)
        }
    }

    @Test("an input named `inputs` is rejected")
    func inputsIsReservedForInputNames() {
        #expect(throws: IdentifierValidationError.invalidIdentifier(kind: .inputName, name: "inputs")) {
            try IdentifierValidation.validate("inputs", kind: .inputName)
        }
    }

    @Test("names reserved only by downstream generators are accepted here")
    func downstreamNamesAreNotReservedHere() throws {
        for name in ["event", "recipients", "render", "values"] {
            try IdentifierValidation.validate(name, kind: .inputName)
        }
    }

    @Test("swiftKeywords excludes generator-specific names")
    func swiftKeywordsArePureKeywords() {
        #expect(IdentifierValidation.swiftKeywords.contains("case"))
        #expect(!IdentifierValidation.swiftKeywords.contains("inputs"))
        #expect(IdentifierValidation.reservedIdentifiers == IdentifierValidation.swiftKeywords.union(["inputs"]))
    }
}
