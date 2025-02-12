//
//  Generate.swift
//  DDDKit
//
//  Created by 卓俊諺 on 2025/2/11.
//


import Foundation
import DDDEventGenerator
import ArgumentParser
import Yams

enum InputType: String, Codable, ExpressibleByArgument {
    case yaml
}

extension AccessLevel: ExpressibleByArgument {
    
}

struct GeneratorConfiguration: Codable {
    enum GenerateKind: String, Codable {
        case event = "event"
        case eventMapper = "event-mapper"
        case aggregateHelper = "aggregate-helper"
    }
    let accessModifier: AccessLevel
    let generate: [GenerateKind]?
}

@main
struct GenerateCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "generate",
        abstract: "Generate swift files.",
        subcommands: [
            Event.self,
            EventMapper.self
        ])
}


extension GenerateCommand {
    enum Errors: Error {
        case outputPathMissing
        case inputFileNotFound
        case illegalInputFile
    }
    
    struct Event: ParsableCommand {
        
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
                throw Errors.outputPathMissing
            }
            
            let accessModifier = accessModifier ?? configuration.accessModifier
            
            let headerGenerator = HeaderGenerator()
            
            var lines: [String] = []
            lines.append(contentsOf: headerGenerator.render())
            lines.append("import Foundation")
            lines.append("import DDDCore")
            lines.append("")
            lines.append(contentsOf: eventGenerator.render(accessLevel: accessModifier))
            
            let content = lines.joined(separator: "\n")
            try content.write(toFile: outputPath, atomically: true, encoding: .utf8)
            
        }
        
    }
    
    struct EventMapper: ParsableCommand {
        
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
            
            let eventMapperGenerator = try EventMapperGenerator(yamlFilePath: input)
            
            guard let outputPath = output else {
                throw Errors.outputPathMissing
            }
            
            let accessModifier = accessModifier ?? configuration.accessModifier
            
            let headerGenerator = HeaderGenerator()

            var lines: [String] = []
            lines.append(contentsOf: headerGenerator.render())
            lines.append("import Foundation")
            lines.append("import DDDCore")
            lines.append("import KurrentSupport")
            lines.append("import KurrentDB")
            lines.append("")
            lines.append(contentsOf: eventMapperGenerator.render(accessLevel: accessModifier))
            
            let content = lines.joined(separator: "\n")
            try content.write(toFile: outputPath, atomically: true, encoding: .utf8)
        }
        
    }
}
