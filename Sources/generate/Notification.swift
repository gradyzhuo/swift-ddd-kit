//
//  Notification.swift
//  DDDKit
//
//  `generate notification` — parses notification.yaml + variables.yaml (notification-definition
//  framework) and renders per-event input structs, recipients, and render(). See spec:
//  docs/superpowers/specs/2026-09-07-notification-definition-design.md §4
//

import Yams
import Foundation
import ArgumentParser
import DomainEventGenerator

struct GenerateNotificationCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "notification",
        abstract: "Generate per-event notification swift files from notification.yaml.")

    @Argument(help: "The path of the notification.yaml file.", completion: .file(extensions: ["yaml", "yam"]))
    var notificationDefinitionPath: String

    @Option(name: .customLong("variables"), help: "The path of the variables.yaml file.", completion: .file(extensions: ["yaml", "yam"]))
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
        let notificationYaml = try String(contentsOf: URL(fileURLWithPath: notificationDefinitionPath), encoding: .utf8)
        let variablesYaml = try String(contentsOf: URL(fileURLWithPath: variablesDefinitionPath), encoding: .utf8)

        let events = try NotificationDefinitionParser.parse(yaml: notificationYaml)
        let variables = try VariablesParser.parse(yaml: variablesYaml)

        guard let outputPath = output else {
            throw GenerateCommand.Errors.outputPathMissing
        }

        let generator = NotificationGenerator(
            protocolName: configuration.variablesProtocolName, events: events, variables: variables)

        for name in generator.unreferencedVariables {
            FileHandle.standardError.write(Data("warning: unreferenced variable \(name)\n".utf8))
        }

        let lines = try generator.render(accessLevel: configuration.accessModifier)

        let content = lines.joined(separator: "\n")
        try content.write(toFile: outputPath, atomically: true, encoding: .utf8)
    }

}
