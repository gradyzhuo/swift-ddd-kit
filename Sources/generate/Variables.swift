//
//  Variables.swift
//  DDDKit
//
//  `generate variables` — parses variables.yaml and renders the variables protocol plus its
//  `__value(of:inputs:)` dispatch seam.
//

import Yams
import Foundation
import ArgumentParser
import TemplateVariablesDefinition

struct GenerateVariablesCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "variables",
        abstract: "Generate a variables protocol swift file from variables.yaml.")

    @Argument(help: "The path of the variables.yaml file.", completion: .file(extensions: ["yaml", "yam"]))
    var variablesDefinitionPath: String

    @Option(name: .customLong("generator-configuration"), help: "The path of variables-generator-config.yaml.", completion: .file(extensions: ["yaml", "yam"]), transform: {
        let yamlData = try Data(contentsOf: URL(fileURLWithPath: $0))
        return try YAMLDecoder().decode(VariablesGeneratorConfiguration.self, from: yamlData)
    })
    var configuration: VariablesGeneratorConfiguration

    @Option(name: .shortAndLong, help: "The path of the generated swift file")
    var output: String? = nil

    func run() throws {
        let yaml = try String(contentsOf: URL(fileURLWithPath: variablesDefinitionPath), encoding: .utf8)
        let variables = try VariablesParser.parse(yaml: yaml)

        guard let outputPath = output else {
            throw GenerateCommand.Errors.outputPathMissing
        }

        let generator = VariablesProtocolGenerator(
            protocolName: configuration.protocolName, variables: variables)
        let content = generator.render(accessLevel: configuration.accessModifier).joined(separator: "\n")
        try content.write(toFile: outputPath, atomically: true, encoding: .utf8)
    }
}
