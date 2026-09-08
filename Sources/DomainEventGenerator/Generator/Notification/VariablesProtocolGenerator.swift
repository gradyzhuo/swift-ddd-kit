//
//  VariablesProtocolGenerator.swift
//  DomainEventGenerator
//
//  Renders the variables protocol + dispatch seam for one `variables.yaml`.
//  The `__value(of:inputs:)` extension is the FROZEN seam Task 3's generated `render()` consumes
//  verbatim — do not change its signature or switch semantics without updating Task 3.
//  See spec: docs/superpowers/specs/2026-09-07-notification-definition-design.md §3
//

import Foundation

package struct VariablesProtocolGenerator {
    let protocolName: String
    let variables: [VariableDefinition]

    package init(protocolName: String, variables: [VariableDefinition]) {
        self.protocolName = protocolName
        self.variables = variables
    }

    package func render(accessLevel: AccessLevel) -> [String] {
        let access = accessLevel.rawValue
        let sortedVariables = variables.sorted { $0.name < $1.name }

        var lines: [String] = []

        // 1. The protocol.
        var protocolLines = ["\(access) protocol \(protocolName): Sendable {"]
        for variable in sortedVariables {
            protocolLines.append("    func \(Self.lowerCamel(variable.name))(\(Self.parameterList(variable.inputs))) async throws -> String")
        }
        protocolLines.append("}")
        lines.append(protocolLines.joined(separator: "\n"))

        // 2. VariablesRuntimeError — emitted once.
        lines.append("""
\(access) enum VariablesRuntimeError: Error, Equatable, Sendable {
    case missingInput(placeholder: String, input: String)
    case unknownPlaceholder(String)
}
""")

        // 3. The dispatch seam. NOTE: the extension itself is emitted unmodified (no access
        // modifier) — `public extension Foo` implicitly applies the access level to its members,
        // which is fine here in isolation, but putting the access level explicitly on `__value`
        // avoids relying on that implicit-access behavior and keeps the emitted extension
        // syntactically identical regardless of accessLevel. Semantics are unchanged either way.
        var seamLines = ["extension \(protocolName) {"]
        seamLines.append("    \(access) func __value(of placeholder: String, inputs: [String: String]) async throws -> String {")
        seamLines.append("        switch placeholder {")
        for variable in sortedVariables {
            seamLines.append("        case \"\(variable.placeholder)\":")
            for input in variable.inputs {
                seamLines.append(
                    "            guard let \(input.name) = inputs[\"\(input.name)\"] else " +
                    "{ throw VariablesRuntimeError.missingInput(placeholder: \"\(variable.placeholder)\", input: \"\(input.name)\") }")
            }
            let arguments = variable.inputs.map { "\($0.name): \($0.name)" }.joined(separator: ", ")
            seamLines.append("            return try await \(Self.lowerCamel(variable.name))(\(arguments))")
        }
        seamLines.append("        default: throw VariablesRuntimeError.unknownPlaceholder(placeholder)")
        seamLines.append("        }")
        seamLines.append("    }")
        seamLines.append("}")
        lines.append(seamLines.joined(separator: "\n"))

        return lines
    }

    private static func parameterList(_ inputs: [(name: String, type: String)]) -> String {
        inputs.map { "\($0.name): \($0.type)" }.joined(separator: ", ")
    }

    private static func lowerCamel(_ name: String) -> String {
        guard let first = name.first else { return name }
        return first.lowercased() + name.dropFirst()
    }
}
