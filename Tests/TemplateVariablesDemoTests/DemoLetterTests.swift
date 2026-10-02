import Testing
import TemplateVariables
@testable import TemplateVariablesDemo

@Suite("TemplateVariablesDemo")
struct DemoLetterTests {

    @Test("dispatch seam resolves each placeholder through its typed method")
    func dispatchResolvesTypedMethods() async throws {
        let variables = DemoLetterVariables()
        #expect(try await variables.__value(of: "CustomerName", inputs: ["customerId": "c-1"]) == "王小明")
        #expect(try await variables.__value(of: "InvoiceTotal", inputs: ["customerId": "c-1", "invoiceId": "i-9"]) == "NT$1,200")
    }

    @Test("missing input throws missingInput naming the placeholder and input")
    func missingInputThrows() async {
        await #expect(throws: VariablesRuntimeError.missingInput(placeholder: "InvoiceTotal", input: "invoiceId")) {
            try await DemoLetterVariables().__value(of: "InvoiceTotal", inputs: ["customerId": "c-1"])
        }
    }

    @Test("unknown placeholder throws unknownPlaceholder")
    func unknownPlaceholderThrows() async {
        await #expect(throws: VariablesRuntimeError.unknownPlaceholder("Nope")) {
            try await DemoLetterVariables().__value(of: "Nope", inputs: [:])
        }
    }

    @Test("resolved values fill a template through PlaceholderSubstitution")
    func resolvedValuesFillTemplate() async throws {
        let variables = DemoLetterVariables()
        let values = [
            "CustomerName": try await variables.__value(of: "CustomerName", inputs: ["customerId": "c-1"]),
            "InvoiceTotal": try await variables.__value(of: "InvoiceTotal", inputs: ["customerId": "c-1", "invoiceId": "i-9"]),
        ]
        let letter = try PlaceholderSubstitution.substitute("%CustomerName% 您好，本期應付 %InvoiceTotal%。", values: values)
        #expect(letter == "王小明 您好，本期應付 NT$1,200。")
    }
}
