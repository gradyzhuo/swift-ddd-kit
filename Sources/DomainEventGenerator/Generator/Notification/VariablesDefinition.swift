//
//  VariablesDefinition.swift
//  DomainEventGenerator
//
//  Parses `variables.yaml` — the notification-definition framework's typed variable contract.
//  See spec: docs/superpowers/specs/2026-09-07-notification-definition-design.md §3
//

import Foundation
import Yams

/// Whether a variable resolves ordinary template text (`environment`, the default) or a
/// notification entry's recipient list (`recipients`, returns `[String]`). See spec:
/// docs/superpowers/specs/2026-09-18-recipients-variable-and-event-metadata-design.md §3.1
package enum VariableType: String, Equatable, Sendable {
    case environment
    case recipients
}

/// One declared template variable: its generated method name, the `%placeholder%` token it
/// resolves, its type (§3.1), and its ordered, single-key `inputs` list (method parameter order).
package struct VariableDefinition: Equatable {
    package let name: String
    package let placeholder: String
    package let type: VariableType
    package let inputs: [(name: String, type: String)]

    package init(
        name: String, placeholder: String, type: VariableType = .environment,
        inputs: [(name: String, type: String)]
    ) {
        self.name = name
        self.placeholder = placeholder
        self.type = type
        self.inputs = inputs
    }

    package static func == (lhs: VariableDefinition, rhs: VariableDefinition) -> Bool {
        lhs.name == rhs.name
            && lhs.placeholder == rhs.placeholder
            && lhs.type == rhs.type
            && lhs.inputs.count == rhs.inputs.count
            && zip(lhs.inputs, rhs.inputs).allSatisfy { $0.name == $1.name && $0.type == $1.type }
    }
}

package enum VariablesParseError: Error, Equatable, Sendable {
    case missingPlaceholder(variable: String)
    case duplicatePlaceholder(placeholder: String)
    case malformedInput(variable: String)
    case unsupportedInputType(variable: String, input: String, type: String)
    case invalidType(variable: String, type: String)
    case metadataOnNonRecipientsVariable(variable: String)
    case explicitMetadataType(variable: String)
}

extension VariablesParseError: CustomStringConvertible {
    package var description: String {
        switch self {
        case .missingPlaceholder(let variable):
            return "variable '\(variable)': missing required `placeholder` key"
        case .duplicatePlaceholder(let placeholder):
            return "placeholder '\(placeholder)' is declared by more than one variable"
        case .malformedInput(let variable):
            return "variable '\(variable)': malformed `inputs` entry (expected an ordered list of single-key `name: SwiftType` maps)"
        case .unsupportedInputType(let variable, let input, let type):
            return "variable '\(variable)': input '\(input)' has unsupported type '\(type)' (only 'String' is supported)"
        case .invalidType(let variable, let type):
            return "variable '\(variable)': unknown `type` value '\(type)' (expected 'environment' or 'recipients')"
        case .metadataOnNonRecipientsVariable(let variable):
            return "variable '\(variable)': `$event.metadata` is only usable on `type: recipients` variables"
        case .explicitMetadataType(let variable):
            return "variable '\(variable)': `$event.metadata` must not have an explicit `: Type` suffix (its type is always Data)"
        }
    }
}

/// Parses `variables.yaml` by walking Yams' `Node` tree directly (rather than `Decodable`),
/// mirroring `KurrentDBProjectionEventItem`'s single-key-map handling — this lets us surface
/// typed, variable-scoped `VariablesParseError`s and preserve `inputs`' declared YAML order.
package enum VariablesParser {
    package static func parse(yaml: String) throws -> [VariableDefinition] {
        guard let root = try Yams.compose(yaml: yaml), let mapping = root.mapping else {
            return []
        }

        var seenPlaceholders: Set<String> = []
        var variables: [VariableDefinition] = []

        for (keyNode, valueNode) in mapping {
            let variableName = keyNode.string ?? ""

            guard let variableMapping = valueNode.mapping,
                  let placeholder = variableMapping["placeholder"]?.string else {
                throw VariablesParseError.missingPlaceholder(variable: variableName)
            }

            guard seenPlaceholders.insert(placeholder).inserted else {
                throw VariablesParseError.duplicatePlaceholder(placeholder: placeholder)
            }

            try IdentifierValidation.validateLowerCamel(variableName, kind: .variableName)

            let type: VariableType
            if let typeValue = variableMapping["type"]?.string {
                guard let parsedType = VariableType(rawValue: typeValue) else {
                    throw VariablesParseError.invalidType(variable: variableName, type: typeValue)
                }
                type = parsedType
            } else {
                type = .environment
            }

            var inputs: [(name: String, type: String)] = []
            if let inputsSequence = variableMapping["inputs"]?.sequence {
                for inputItem in inputsSequence {
                    // `$event.metadata` is the one `inputs:` entry allowed to be a bare scalar
                    // (no `mapping`) rather than a single-key `name: Type` map.
                    if inputItem.mapping == nil, let scalar = inputItem.string {
                        guard scalar == "$event.metadata" else {
                            throw VariablesParseError.malformedInput(variable: variableName)
                        }
                        guard type == .recipients else {
                            throw VariablesParseError.metadataOnNonRecipientsVariable(variable: variableName)
                        }
                        inputs.append((name: "eventMetadata", type: "Data"))
                        continue
                    }

                    guard let inputMapping = inputItem.mapping, inputMapping.count == 1,
                          let pair = inputMapping.first else {
                        throw VariablesParseError.malformedInput(variable: variableName)
                    }
                    let inputName = pair.key.string ?? ""
                    let inputType = pair.value.string ?? ""
                    guard inputName != "$event.metadata" else {
                        throw VariablesParseError.explicitMetadataType(variable: variableName)
                    }
                    guard inputType == "String" else {
                        throw VariablesParseError.unsupportedInputType(
                            variable: variableName, input: inputName, type: inputType)
                    }
                    try IdentifierValidation.validate(inputName, kind: .inputName)
                    inputs.append((name: inputName, type: inputType))
                }
            }

            variables.append(VariableDefinition(name: variableName, placeholder: placeholder, type: type, inputs: inputs))
        }

        return variables
    }
}
