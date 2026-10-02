//
//  DemoLetterVariables.swift
//  TemplateVariablesDemo
//
//  Hand-written conformer to the GENERATED `DemoLetterVariablesProtocol` (from variables.yaml via
//  VariablesGeneratorPlugin). Canned values — this target proves the codegen chain compiles and
//  dispatches, not a real read model.
//

public struct DemoLetterVariables: DemoLetterVariablesProtocol {
    public init() {}

    public func customerName(customerId: String) async throws -> String { "王小明" }

    public func invoiceTotal(customerId: String, invoiceId: String) async throws -> String { "NT$1,200" }
}
