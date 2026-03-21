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

struct AccessLevelArgument: ExpressibleByArgument {
    let value: AccessLevel
    
    init?(argument: String) {
        // 你的解析邏輯
        self.value = .init(rawValue: argument) ?? .internal
    }
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
    let aggregateRootName: String?
}

@main
struct GenerateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate",
        abstract: "Generate swift files.",
        subcommands: [
            GenerateEventCommand.self,
            GenerateEventMapperCommand.self,
            GenerateModelCommand.self
        ])
}


extension GenerateCommand {
    enum Errors: Error {
        case outputPathMissing
        case inputFileNotFound
        case illegalInputFile
    }
}
