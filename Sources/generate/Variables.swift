//
//  Variables.swift
//  DDDKit
//
//  `generate variables` — parses variables.yaml (notification-definition framework) and
//  renders the variables protocol + dispatch seam. See spec:
//  docs/superpowers/specs/2026-09-07-notification-definition-design.md §3
//

import Yams
import Foundation
import ArgumentParser
import DomainEventGenerator

struct GenerateVariablesCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "variables",
        abstract: "Generate a variables protocol swift file from variables.yaml.")

    @Argument(help: "The path of the variables.yaml file.", completion: .file(extensions: ["yaml", "yam"]))
    var variablesDefinitionPath: String

    @Option(name: .customLong("generator-configuration"), completion: .file(extensions: ["yaml", "yam"]), transform: {
        let url = URL(fileURLWithPath: $0)
        let yamlData = try Data(contentsOf: url)
        let yamlDecoder = YAMLDecoder()
        return try yamlDecoder.decode(NotificationGeneratorConfiguration.self, from: yamlData)
    })
    var configuration: NotificationGeneratorConfiguration

    @Option(name: .shortAndLong, help: "The path of the generated swift file")
    var output: String? = nil

    func run() throws {
        let yaml = try String(contentsOf: URL(fileURLWithPath: variablesDefinitionPath), encoding: .utf8)
        let variables = try VariablesParser.parse(yaml: yaml)

        guard let outputPath = output else {
            throw GenerateCommand.Errors.outputPathMissing
        }

        let generator = VariablesProtocolGenerator(
            protocolName: configuration.variablesProtocolName, variables: variables)

        var lines: [String] = []
        lines.append(contentsOf: generator.render(accessLevel: configuration.accessModifier))

        let content = lines.joined(separator: "\n")
        try content.write(toFile: outputPath, atomically: true, encoding: .utf8)
    }

}
