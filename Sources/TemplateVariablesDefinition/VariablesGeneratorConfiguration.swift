//
//  VariablesGeneratorConfiguration.swift
//  TemplateVariablesDefinition
//
//  Decoded from a target's `variables-generator-config.yaml`. Every generator that emits code
//  against the variables protocol reads this one file, so the protocol name is declared once.
//

public struct VariablesGeneratorConfiguration: Codable, Sendable, Equatable {
    public let accessModifier: TemplateAccessLevel
    public let protocolName: String

    public init(accessModifier: TemplateAccessLevel, protocolName: String) {
        self.accessModifier = accessModifier
        self.protocolName = protocolName
    }

    /// The file name generators look for in a target's sources.
    public static let fileName = "variables-generator-config.yaml"
}
