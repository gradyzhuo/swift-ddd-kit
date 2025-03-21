//
//  Generate.swift
//  DDDKit
//
//  Created by 卓俊諺 on 2025/2/11.
//


import Foundation
import DomainEventGenerator
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
        case projectionModel = "projection-model"
    }
    let accessModifier: AccessLevel
    let dependencies: [String]?
    let generate: [GenerateKind]?
}

@main
struct GenerateCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "generate",
        abstract: "Generate swift files.",
        subcommands: [
            GenerateEventCommand.self,
            GenerateEventMapperCommand.self,
            GenerateProjectionModelCommand.self
        ])
}


extension GenerateCommand {
    enum Errors: Error {
        case outputPathMissing
        case inputFileNotFound
        case illegalInputFile
    }
}
