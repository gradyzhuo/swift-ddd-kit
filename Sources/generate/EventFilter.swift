//
//  EventFilter.swift
//  DDDKit
//
//  event-filter CLI subcommand — parallel to event-mapper.
//  Generates `generated-event-filter.swift` containing one `*EventFilter` struct
//  per projection model declared in projection-model.yaml.
//

import Yams
import Foundation
import ArgumentParser
import DomainEventGenerator

struct GenerateEventFilterCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "event-filter",
        abstract: "Generate event-filter swift files.")

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
    var defaultAggregateRootName: String

    @Option
    var accessModifier: AccessLevelArgument?

    @Option(name: .shortAndLong, help: "The path of the generated swift file")
    var output: String? = nil

    func run() throws {
        let projectorGenerator = try ProjectorGenerator(
            projectionModelYamlFileURL: .init(filePath: projectionModelDefinitionPath)
        )

        guard let outputPath = output else {
            throw GenerateCommand.Errors.outputPathMissing
        }

        let accessModifier = accessModifier?.value ?? configuration.accessModifier

        // EventTypeFilter lives in EventSourcing — that's the only required dep.
        let defaultDependencies = ["EventSourcing"]
        let configDependencies = configuration.dependencies ?? []
        let headerGenerator = HeaderGenerator(
            dependencies: defaultDependencies + configDependencies
        )

        var lines: [String] = []
        lines.append(contentsOf: headerGenerator.render())
        lines.append("")

        // One filter per projection model. Aggregate root is NOT included —
        // filters are read-side only.
        for (modelName, projectionModelDefinition) in projectorGenerator.definitions {
            var eventNames = projectionModelDefinition.events
            eventNames.append(contentsOf: projectionModelDefinition.createdEvents)
            if let deletedEvent = projectionModelDefinition.deletedEvent {
                eventNames.append(deletedEvent)
            }
            let filterGenerator = EventFilterGenerator(modelName: modelName, eventNames: eventNames)
            lines.append(contentsOf: filterGenerator.render(accessLevel: accessModifier))
            lines.append("")
        }

        let content = lines.joined(separator: "\n")
        try content.write(toFile: outputPath, atomically: true, encoding: .utf8)
    }
}
