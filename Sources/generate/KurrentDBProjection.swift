//
//  KurrentDBProjection.swift
//  DDDKit
//
//  Created by Grady Zhuo on 2026/4/6.
//

import Foundation
import ArgumentParser
import DomainEventGenerator

struct GenerateKurrentDBProjectionCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "kurrentdb-projection",
        abstract: "Generate KurrentDB .js projection files from projection-model.yaml.")

    @Argument(help: "The path of the projection-model.yaml file.",
              completion: .file(extensions: ["yaml", "yml"]))
    var input: String

    @Option(name: .shortAndLong,
            help: "The output directory for generated .js files. Default: projections/")
    var output: String = "projections"

    func run() throws {
        let inputURL = URL(fileURLWithPath: input)
        let outputURL = URL(fileURLWithPath: output)
        let fileGenerator = try KurrentDBProjectionFileGenerator(projectionModelYamlFileURL: inputURL)
        try fileGenerator.writeFiles(to: outputURL)
    }
}
