//
//  GenerateCommand.ProjectionModel.swift
//  DDDKit
//
//  Created by Grady Zhuo on 2025/2/15.
//
import Yams
import Foundation
import ArgumentParser
import DomainEventGenerator

struct GenerateProjectionModelCommand: ParsableCommand {
    
    static var configuration = CommandConfiguration(
        commandName: "projection-model",
        abstract: "Generate projection model swift files.")
    
    @Option(name: .customLong("events"),completion: .file(extensions: ["yaml", "yam"]))
    var eventDefinitionPath: String
    
    @Argument(help: "The path of the projection-model file.", completion: .file(extensions: ["yaml", "yam"]))
    var projectionModelDefinitionPath: String
    
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
        
        let eventGenerator = try EventGenerator(yamlFilePath: eventDefinitionPath)
        
        let filteredVaildCreatedEventDefinition: [Event] = eventGenerator.events.filter{
            let deprecated = $0.definition.deprecated ?? false
            return !deprecated && $0.definition.kind == .createdEvent
        }
        let createdEventDefinition = filteredVaildCreatedEventDefinition.first
        
        let generator = try ProjectionModelGenerator(yamlFilePath: projectionModelDefinitionPath, aggregateEventNames: eventGenerator.eventNames)
        
        guard let outputPath = output else {
            throw GenerateCommand.Errors.outputPathMissing
        }
        
        let accessModifier = accessModifier ?? configuration.accessModifier
        
        let headerGenerator = HeaderGenerator(dependencies: ["Foundation", "DDDCore"])

        var lines: [String] = []
        lines.append(contentsOf: headerGenerator.render())
        lines.append("import Foundation")
        lines.append("import DDDCore")
        lines.append("")
        lines.append(contentsOf: generator.render(accessLevel: accessModifier))
        
        let content = lines.joined(separator: "\n")
        try content.write(toFile: outputPath, atomically: true, encoding: .utf8)
    }
    
}
