//
//  KurrentDBProjectionGenerator.swift
//  DDDKit
//

import Foundation
import Yams

package struct KurrentDBProjectionGenerator {
    package let name: String
    package let definition: EventProjectionDefinition

    package init(name: String, definition: EventProjectionDefinition) {
        self.name = name
        self.definition = definition
    }

    /// Returns `nil` when `definition.category` is absent — definition is not a KurrentDB projection.
    /// Throws `KurrentDBProjectionError` for invalid configurations (e.g., plain event without idField).
    package func render() throws -> String? {
        guard let category = definition.category else { return nil }

        var lines: [String] = []
        lines.append(#"fromStreams(["$ce-\#(category)"])"#)
        lines.append(".when({")
        lines.append("    $init: function(){ return {} },")

        let allItems = definition.createdKurrentDBEvents + definition.kurrentDBEvents
        for item in allItems {
            try lines.append(contentsOf: renderHandler(item: item))
        }

        lines.append("});")
        return lines.joined(separator: "\n")
    }

    private func renderHandler(item: KurrentDBProjectionEventItem) throws -> [String] {
        var lines: [String] = []
        lines.append("    \(item.name): function(state, event) {")
        lines.append("        if (event.isJson) {")

        switch item {
        case .plain(let eventName):
            guard let idField = definition.idField else {
                throw KurrentDBProjectionError.missingIdFieldForPlainEvent(
                    modelName: name, eventName: eventName)
            }
            lines.append(#"            linkTo("\#(name)-" + event.body["\#(idField)"], event);"#)

        case .custom(_, let body):
            let bodyLines = body.components(separatedBy: "\n")
            for bodyLine in bodyLines where !bodyLine.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("            \(bodyLine)")
            }
        }

        lines.append("        }")
        lines.append("    },")
        return lines
    }
}

/// Reads `projection-model.yaml` and writes one `.js` file per definition that has a `category`.
package struct KurrentDBProjectionFileGenerator {
    package let definitions: [String: EventProjectionDefinition]

    package init(projectionModelYamlFileURL: URL) throws {
        let yamlData = try Data(contentsOf: projectionModelYamlFileURL)
        guard !yamlData.isEmpty else {
            throw DomainEventGeneratorError.invalidYamlFile(
                url: projectionModelYamlFileURL, reason: "The yaml file is empty.")
        }
        let yamlDecoder = YAMLDecoder()
        // Decode errors propagate; unlike ProjectorGenerator, we do not swallow them.
        self.definitions = try yamlDecoder.decode([String: EventProjectionDefinition].self, from: yamlData)
    }

    package func writeFiles(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, definition) in definitions {
            let generator = KurrentDBProjectionGenerator(name: name, definition: definition)
            guard let js = try generator.render() else { continue }
            let outputURL = directory.appendingPathComponent("\(name)Projection.js")
            try js.write(to: outputURL, atomically: true, encoding: .utf8)
        }
    }
}
