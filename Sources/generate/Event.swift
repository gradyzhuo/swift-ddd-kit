//
//  Event.swift
//  DDDKit
//
//  Created by Grady Zhuo on 2025/2/15.
//

import Yams
import Foundation
import ArgumentParser
import DomainEventGenerator

struct GenerateEventCommand: ParsableCommand {
    
    static var configuration = CommandConfiguration(
        commandName: "event",
        abstract: "Generate event swift files.")
    
    @Argument(help: "The path of the event file.", completion: .file(extensions: ["yaml", "yam"]))
    var input: String
    
    @Option(completion: .file(extensions: ["yaml", "yam"]), transform: {
        let url = URL(fileURLWithPath: $0)
        let yamlData = try Data(contentsOf: url)
        let yamlDecoder = YAMLDecoder()
        return try yamlDecoder.decode(GeneratorConfiguration.self, from: yamlData)
    })
    var configuration: GeneratorConfiguration
    
    @Option
    var inputType: InputType = .yaml
    
    @Option
    var accessModifier: AccessLevel?
    
    @Option(name: .shortAndLong, help: "The path of the generated swift file")
    var output: String? = nil
    
    func run() throws {
        let eventGenerator = try EventGenerator(yamlFilePath: input)
        
        guard let outputPath = output else {
            throw GenerateCommand.Errors.outputPathMissing
        }
        
        let accessModifier = accessModifier ?? configuration.accessModifier
        
        let defaultDependencies = ["Foundation", "DDDCore"]
        let configDependencies = configuration.dependencies ?? []
        let headerGenerator = HeaderGenerator(dependencies: defaultDependencies + configDependencies)
        
        var lines: [String] = []
        lines.append(contentsOf: headerGenerator.render())
        lines.append("")
        lines.append(contentsOf: eventGenerator.render(accessLevel: accessModifier))
        
        let content = lines.joined(separator: "\n")
        try content.write(toFile: outputPath, atomically: true, encoding: .utf8)
        
    }
    
}
