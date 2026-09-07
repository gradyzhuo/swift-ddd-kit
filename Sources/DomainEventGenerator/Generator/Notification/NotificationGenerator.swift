//
//  NotificationGenerator.swift
//  DomainEventGenerator
//
//  Renders, per event declared in `notification.yaml`, a Decodable input struct and an enum
//  with `recipients(input:)` + `render(input:variables:)`, cross-validated against
//  `variables.yaml`. Consumes the `__value(of:inputs:)` seam emitted by
//  `VariablesProtocolGenerator` verbatim.
//  See spec: docs/superpowers/specs/2026-09-07-notification-definition-design.md §4
//

import Foundation

package enum NotificationGenerateError: Error, Equatable, Sendable {
    case undefinedPlaceholder(event: String, placeholder: String)
}

package struct NotificationGenerator {
    let protocolName: String
    let events: [EventNotificationDefinition]
    let variables: [VariableDefinition]

    package init(protocolName: String, events: [EventNotificationDefinition], variables: [VariableDefinition]) {
        self.protocolName = protocolName
        self.events = events
        self.variables = variables
    }

    /// Variables defined in `variables.yaml` but never referenced by any event's templates.
    /// Not part of the generated code — the CLI layer prints these as `warning:` lines.
    package var unreferencedVariables: [String] {
        var referencedPlaceholders: Set<String> = []
        for event in events {
            for entry in event.notifications {
                for field in entry.fields {
                    referencedPlaceholders.formUnion(PlaceholderExtractor.placeholders(in: field.template))
                }
            }
        }
        return variables
            .filter { !referencedPlaceholders.contains($0.placeholder) }
            .map { $0.name }
            .sorted()
    }

    package func render(accessLevel: AccessLevel) throws -> [String] {
        let access = accessLevel.rawValue
        let variablesByPlaceholder = Dictionary(uniqueKeysWithValues: variables.map { ($0.placeholder, $0) })
        let sortedEvents = events.sorted { $0.eventName < $1.eventName }

        var lines: [String] = ["import NotificationDefinition"]

        for event in sortedEvents {
            // Distinct placeholders referenced by this event, in first-appearance order across
            // all notification entries/fields (order only matters for validation; declaration
            // order in the generated code is alphabetical for determinism — see below).
            var orderedPlaceholders: [String] = []
            var seenPlaceholders: Set<String> = []
            for entry in event.notifications {
                for field in entry.fields {
                    for placeholder in PlaceholderExtractor.placeholders(in: field.template) {
                        if seenPlaceholders.insert(placeholder).inserted {
                            orderedPlaceholders.append(placeholder)
                        }
                    }
                }
            }

            var matchedVariables: [VariableDefinition] = []
            for placeholder in orderedPlaceholders {
                guard let variable = variablesByPlaceholder[placeholder] else {
                    throw NotificationGenerateError.undefinedPlaceholder(event: event.eventName, placeholder: placeholder)
                }
                matchedVariables.append(variable)
            }

            let sortedPlaceholders = orderedPlaceholders.sorted()

            var propertyNames: Set<String> = Set(event.recipients)
            for variable in matchedVariables {
                for input in variable.inputs {
                    propertyNames.insert(input.name)
                }
            }
            let sortedProperties = propertyNames.sorted()

            lines.append(Self.renderInputStruct(access: access, event: event, properties: sortedProperties))
            lines.append(
                Self.renderNotificationEnum(
                    access: access,
                    protocolName: protocolName,
                    event: event,
                    properties: sortedProperties,
                    placeholders: sortedPlaceholders
                ))
        }

        return lines
    }

    private static func renderInputStruct(access: String, event: EventNotificationDefinition, properties: [String]) -> String {
        var lines = ["\(access) struct \(event.eventName)NotificationInput: Decodable {"]
        for property in properties {
            lines.append("    \(access) let \(property): String")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private static func renderNotificationEnum(
        access: String,
        protocolName: String,
        event: EventNotificationDefinition,
        properties: [String],
        placeholders: [String]
    ) -> String {
        var lines = ["\(access) enum \(event.eventName)Notification {"]

        // recipients(input:)
        lines.append("    \(access) static func recipients(input: \(event.eventName)NotificationInput) -> [String] {")
        let recipientExpressions = event.recipients.map { "input.\($0)" }.joined(separator: ", ")
        lines.append("        [\(recipientExpressions)]")
        lines.append("    }")
        lines.append("")

        // render(input:variables:)
        lines.append(
            "    \(access) static func render(input: \(event.eventName)NotificationInput, variables: some \(protocolName)) async throws -> [RenderedNotification] {")
        lines.append("        let inputs: [String: String] = [")
        for property in properties {
            lines.append("            \"\(property)\": input.\(property),")
        }
        lines.append("        ]")

        for placeholder in placeholders {
            let letName = Self.lowerCamel(placeholder)
            lines.append("        let \(letName) = try await variables.__value(of: \"\(placeholder)\", inputs: inputs)")
        }

        if !placeholders.isEmpty {
            lines.append("        let values: [String: String] = [")
            for placeholder in placeholders {
                lines.append("            \"\(placeholder)\": \(Self.lowerCamel(placeholder)),")
            }
            lines.append("        ]")
        }

        lines.append("        return [")
        for entry in event.notifications {
            lines.append("            RenderedNotification(")
            lines.append("                type: NotificationType(rawValue: \"\(entry.type)\")!,")
            lines.append("                fields: [")
            for field in entry.fields {
                let escapedTemplate = Self.escapeSwiftStringLiteral(field.template)
                let valuesArgument = placeholders.isEmpty ? "[:]" : "values"
                lines.append(
                    "                    \"\(field.name)\": try PlaceholderSubstitution.substitute(\"\(escapedTemplate)\", values: \(valuesArgument)),")
            }
            lines.append("                ]")
            lines.append("            ),")
        }
        lines.append("        ]")
        lines.append("    }")
        lines.append("}")

        return lines.joined(separator: "\n")
    }

    private static func lowerCamel(_ name: String) -> String {
        guard let first = name.first else { return name }
        return first.lowercased() + name.dropFirst()
    }

    private static func escapeSwiftStringLiteral(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return escaped
    }
}
