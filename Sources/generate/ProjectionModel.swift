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
    
    static let configuration = CommandConfiguration(
        commandName: "presenter",
        abstract: "Generate presenter protocol swift files.")
    
    @Option(name: .customLong("events"),completion: .file(extensions: ["yaml", "yam"]))
    var eventDefinitionPath: String
    
    @Argument(help: "The path of the projection-model file.", completion: .file(extensions: ["yaml", "yam"]))
    var projectionModelDefinitionPath: String
    
    @Option(name: .customLong("generator-configuration"),completion: .file(extensions: ["yaml", "yam"]), transform: {
        let url = URL(fileURLWithPath: $0)
        let yamlData = try Data(contentsOf: url)
        let yamlDecoder = YAMLDecoder()
        return try yamlDecoder.decode(GeneratorConfiguration.self, from: yamlData)
    })
    var configuration: GeneratorConfiguration
    
    @Option
    var defaultAggregateRootName: String
    
    @Option
    var inputType: InputType = .yaml
    
    @Option
    var accessModifier: AccessLevelArgument?
    
    @Option(name: .shortAndLong, help: "The path of the generated swift file")
    var output: String? = nil
    
    func run() throws {
        
        let aggregateRootName = configuration.aggregateRootName ?? defaultAggregateRootName
        
        let aggregateRootGenerator = try AggregateRootGenerator(aggregateRootName: aggregateRootName, aggregateEventsYamlFileURL: .init(filePath: eventDefinitionPath))
        
        let generator = try ProjectionModelGenerator(projectionModelYamlFileURL: .init(filePath: projectionModelDefinitionPath), aggregateRootName: aggregateRootName, aggregateEventsYamlFileURL: .init(filePath: eventDefinitionPath))
    
        guard let outputPath = output else {
            throw GenerateCommand.Errors.outputPathMissing
        }
        
        let accessModifier = accessModifier?.value ?? configuration.accessModifier
        
        let defaultDependencies = ["Foundation", "DDDCore"]
        let configDependencies = configuration.dependencies ?? []
        let headerGenerator = HeaderGenerator(dependencies: defaultDependencies + configDependencies)
        
        var lines: [String] = []
        lines.append(contentsOf: headerGenerator.render())
        lines.append("")
        lines.append(contentsOf: generator.render(accessLevel: accessModifier))
        
        let content = lines.joined(separator: "\n")
        try content.write(toFile: outputPath, atomically: true, encoding: .utf8)
    }
    
    
}
