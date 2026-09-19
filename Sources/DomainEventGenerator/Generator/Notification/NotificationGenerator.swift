//
//  NotificationGenerator.swift
//  DomainEventGenerator
//
//  For each (event, notification entry) pair declared in `notification.yaml`, generates a
//  protocol the consumer implements — exposing the real `DomainEvent`, the entry's own known
//  text-template fields, a `recipients()` requirement, and an overridable `render()` — plus an
//  extension providing `render()`'s default implementation. Cross-validated against
//  `variables.yaml`. Consumes the `__value(of:inputs:)` seam emitted by
//  `VariablesProtocolGenerator` verbatim.
//  See spec: docs/superpowers/specs/2026-09-19-per-entry-notification-recipients-protocol-design.md
//

import Foundation

package enum NotificationGenerateError: Error, Equatable, Sendable {
    case undefinedPlaceholder(event: String, placeholder: String)
    /// Two entries in the same event have different `id`s that transform to the same
    /// PascalCase-with-underscore name (e.g. `test-abc` and `test_abc` both become `Test_Abc`),
    /// which would otherwise silently collide as the same generated protocol name.
    case duplicateGeneratedProtocolName(event: String, a: String, b: String)
}

extension NotificationGenerateError: CustomStringConvertible {
    package var description: String {
        switch self {
        case .undefinedPlaceholder(let event, let placeholder):
            return "event '\(event)': placeholder '%\(placeholder)%' has no matching variable in variables.yaml"
        case .duplicateGeneratedProtocolName(let event, let a, let b):
            return "event '\(event)': ids '\(a)' and '\(b)' both produce the same generated protocol name — rename one"
        }
    }
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

        var lines: [String] = ["import DDDCore", "import Foundation", "import NotificationDefinition"]

        for event in sortedEvents {
            // Detect two ids in this event that would produce the same generated protocol name
            // before emitting anything for this event.
            var idPascalToId: [String: String] = [:]
            for entry in event.notifications {
                let idPascal = Self.idPascalCase(entry.id)
                if let existingId = idPascalToId[idPascal], existingId != entry.id {
                    throw NotificationGenerateError.duplicateGeneratedProtocolName(
                        event: event.eventName, a: existingId, b: entry.id)
                }
                idPascalToId[idPascal] = entry.id
            }

            for entry in event.notifications {
                lines.append(
                    try Self.renderEntry(
                        access: access,
                        protocolName: protocolName,
                        event: event,
                        entry: entry,
                        variablesByPlaceholder: variablesByPlaceholder))
            }
        }

        return lines
    }

    /// Renders one entry's generated protocol + default-implementation extension.
    private static func renderEntry(
        access: String,
        protocolName: String,
        event: EventNotificationDefinition,
        entry: NotificationEntry,
        variablesByPlaceholder: [String: VariableDefinition]
    ) throws -> String {
        // Distinct placeholders referenced by THIS ENTRY's own fields (not the whole event), in
        // first-appearance order — order only matters for validation; declaration order in the
        // generated code is alphabetical for determinism (see sortedPlaceholders below).
        var orderedPlaceholders: [String] = []
        var seenPlaceholders: Set<String> = []
        for field in entry.fields {
            for placeholder in PlaceholderExtractor.placeholders(in: field.template) {
                if seenPlaceholders.insert(placeholder).inserted {
                    orderedPlaceholders.append(placeholder)
                }
            }
        }

        // Every placeholder becomes a `let <lowerCamel(placeholder)> = ...` local in the
        // generated `render()` — validate that transform is a legal, non-reserved Swift
        // identifier, and that no two distinct placeholders collide on it.
        var localNamesByPlaceholder: [String: String] = [:]
        for placeholder in orderedPlaceholders {
            try IdentifierValidation.validateLowerCamel(placeholder, kind: .placeholder)
            let localName = IdentifierValidation.lowerCamel(placeholder)
            if let existing = localNamesByPlaceholder[localName] {
                throw IdentifierValidationError.identifierCollision(a: existing, b: placeholder)
            }
            localNamesByPlaceholder[localName] = placeholder
        }

        var matchedVariables: [VariableDefinition] = []
        for placeholder in orderedPlaceholders {
            guard let variable = variablesByPlaceholder[placeholder] else {
                throw NotificationGenerateError.undefinedPlaceholder(event: event.eventName, placeholder: placeholder)
            }
            matchedVariables.append(variable)
        }

        let sortedPlaceholders = orderedPlaceholders.sorted()

        var propertyNames: Set<String> = []
        for variable in matchedVariables {
            for input in variable.inputs {
                propertyNames.insert(input.name)
            }
        }
        let sortedProperties = propertyNames.sorted()

        let idPascal = Self.idPascalCase(entry.id)
        let protocolTypeName = "\(event.eventName)Notification\(idPascal)Protocol"

        return Self.renderProtocolAndExtension(
            access: access,
            protocolName: protocolName,
            protocolTypeName: protocolTypeName,
            entry: entry,
            properties: sortedProperties,
            placeholders: sortedPlaceholders
        )
    }

    /// `test-abc-mail` -> `Test_Abc_Mail`: split on `-`/`_`, uppercase each segment's first
    /// letter, rejoin with `_`.
    private static func idPascalCase(_ id: String) -> String {
        id.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { segment -> String in
                guard let first = segment.first else { return String(segment) }
                return first.uppercased() + segment.dropFirst()
            }
            .joined(separator: "_")
    }

    private static func renderProtocolAndExtension(
        access: String,
        protocolName: String,
        protocolTypeName: String,
        entry: NotificationEntry,
        properties: [String],
        placeholders: [String]
    ) -> String {
        var lines: [String] = []

        // 1. The protocol.
        lines.append("\(access) protocol \(protocolTypeName): Sendable {")
        lines.append("    associatedtype DomainEventType: DomainEvent")
        lines.append("    var event: DomainEventType { get }")
        lines.append("")
        for property in properties {
            lines.append("    var \(property): String { get }")
        }
        if !properties.isEmpty { lines.append("") }
        lines.append("    func recipients() async throws -> [String]")
        lines.append("    func render(variables: some \(protocolName)) async throws -> RenderedNotification")
        lines.append("}")
        lines.append("")

        // 2. Default render() implementation.
        lines.append("extension \(protocolTypeName) {")
        lines.append("    \(access) func render(variables: some \(protocolName)) async throws -> RenderedNotification {")

        if !placeholders.isEmpty {
            if properties.isEmpty {
                // A template can reference a variable declared with an empty `inputs:` list (e.g.
                // a zero-parameter variable) — `properties` is then empty even though
                // `placeholders` isn't. `[String: String] = [\n]` is invalid Swift; emit the
                // empty-dictionary literal form instead.
                lines.append("        let inputs: [String: String] = [:]")
            } else {
                lines.append("        let inputs: [String: String] = [")
                for property in properties {
                    lines.append("            \"\(property)\": \(property),")
                }
                lines.append("        ]")
            }
        }

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

        lines.append("        return RenderedNotification(")
        lines.append("            type: NotificationType(rawValue: \"\(entry.type)\")!,")
        lines.append("            recipients: try await self.recipients(),")
        lines.append("            fields: [")
        for field in entry.fields {
            let escapedTemplate = Self.escapeSwiftStringLiteral(field.template)
            let valuesArgument = placeholders.isEmpty ? "[:]" : "values"
            // `content` fields' handling depends on the entry's resolved `render` value — see
            // docs/superpowers/specs/2026-09-09-markdown-notification-content-design.md §3-4 and
            // docs/superpowers/specs/2026-09-15-inapp-render-format-design.md §3.
            if field.name == "content", entry.render == .markdown {
                lines.append(
                    "                \"\(field.name)\": MarkdownRendering.html(from: try PlaceholderSubstitution.substitute(\"\(escapedTemplate)\", values: \(valuesArgument), escaping: .markdown)),"
                )
            } else {
                lines.append(
                    "                \"\(field.name)\": try PlaceholderSubstitution.substitute(\"\(escapedTemplate)\", values: \(valuesArgument)),"
                )
            }
        }
        if entry.type == "inApp" {
            // Wire model: inApp carries its resolved render format alongside title/content
            // (mail's render choice is fully resolved into HTML upstream, so mail never gets
            // this field).
            lines.append("                \"render\": \"\(entry.render.rawValue)\",")
        }
        lines.append("            ])")
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
