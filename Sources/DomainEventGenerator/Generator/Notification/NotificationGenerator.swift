//
//  NotificationGenerator.swift
//  DomainEventGenerator
//
//  Renders, per event declared in `notification.yaml`, a Decodable input struct and an enum
//  with `render(input:variables:)`, cross-validated against `variables.yaml`. Each returned
//  `RenderedNotification` carries its own entry's `recipients`. Consumes the `__value(of:inputs:)`
//  seam emitted by `VariablesProtocolGenerator` verbatim.
//  See spec: docs/superpowers/specs/2026-09-07-notification-definition-design.md §4
//

import Foundation

package enum NotificationGenerateError: Error, Equatable, Sendable {
    case undefinedPlaceholder(event: String, placeholder: String)
    case recipientsVariableUsedAsPlaceholder(event: String, placeholder: String)
    case undefinedRecipientsVariable(event: String, variable: String)
    case recipientsVariableWrongType(event: String, variable: String)
}

extension NotificationGenerateError: CustomStringConvertible {
    package var description: String {
        switch self {
        case .undefinedPlaceholder(let event, let placeholder):
            return "event '\(event)': placeholder '%\(placeholder)%' has no matching variable in variables.yaml"
        case .recipientsVariableUsedAsPlaceholder(let event, let placeholder):
            return "event '\(event)': '%\(placeholder)%' is a type: recipients variable and cannot be used inside a text template — use %recipients:\(placeholder)% in a recipients: list instead"
        case .undefinedRecipientsVariable(let event, let variable):
            return "event '\(event)': %recipients:\(variable)% has no matching variable in variables.yaml"
        case .recipientsVariableWrongType(let event, let variable):
            return "event '\(event)': %recipients:\(variable)% names a type: environment variable — only type: recipients variables can be used in a recipients: list"
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

    /// Variables defined in `variables.yaml` but never referenced by any event's templates or
    /// `%recipients:X%` tokens. Not part of the generated code — the CLI layer prints these as
    /// `warning:` lines.
    package var unreferencedVariables: [String] {
        var referencedPlaceholders: Set<String> = []
        var referencedRecipientsVariableNames: Set<String> = []
        for event in events {
            for entry in event.notifications {
                for field in entry.fields {
                    referencedPlaceholders.formUnion(PlaceholderExtractor.placeholders(in: field.template))
                }
                for recipient in entry.recipients {
                    if case .variable(let variableName) = recipient {
                        referencedRecipientsVariableNames.insert(variableName)
                    }
                }
            }
        }
        return variables
            .filter { variable in
                let referencedAsPlaceholder = referencedPlaceholders.contains(variable.placeholder)
                let referencedAsRecipientsToken =
                    variable.type == .recipients && referencedRecipientsVariableNames.contains(variable.name)
                return !referencedAsPlaceholder && !referencedAsRecipientsToken
            }
            .map { $0.name }
            .sorted()
    }

    package func render(accessLevel: AccessLevel) throws -> [String] {
        let access = accessLevel.rawValue
        let variablesByPlaceholder = Dictionary(uniqueKeysWithValues: variables.map { ($0.placeholder, $0) })
        let variablesByName = Dictionary(uniqueKeysWithValues: variables.map { ($0.name, $0) })
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
                guard variable.type == .environment else {
                    throw NotificationGenerateError.recipientsVariableUsedAsPlaceholder(event: event.eventName, placeholder: placeholder)
                }
                matchedVariables.append(variable)
            }

            let sortedPlaceholders = orderedPlaceholders.sorted()

            // Every `%recipients:X%` token referenced by this event's recipients: lists, matched
            // and type-checked against variables.yaml — mirrors matchedVariables above.
            var matchedRecipientsVariables: [VariableDefinition] = []
            var seenRecipientsVariableNames: Set<String> = []
            for notification in event.notifications {
                for recipient in notification.recipients {
                    guard case .variable(let variableName) = recipient else { continue }
                    guard let variable = variablesByName[variableName] else {
                        throw NotificationGenerateError.undefinedRecipientsVariable(event: event.eventName, variable: variableName)
                    }
                    guard variable.type == .recipients else {
                        throw NotificationGenerateError.recipientsVariableWrongType(event: event.eventName, variable: variableName)
                    }
                    if seenRecipientsVariableNames.insert(variableName).inserted {
                        matchedRecipientsVariables.append(variable)
                    }
                }
            }

            // Every Input struct property, with its Swift type — almost always "String", except
            // a type: recipients variable's `$event.metadata` input, typed "Data".
            var propertyTypes: [String: String] = [:]
            for notification in event.notifications {
                for recipient in notification.recipients {
                    if case .field(let name) = recipient {
                        propertyTypes[name] = "String"
                    }
                }
            }
            for variable in matchedVariables {
                for input in variable.inputs {
                    propertyTypes[input.name] = input.type
                }
            }
            for variable in matchedRecipientsVariables {
                for input in variable.inputs {
                    propertyTypes[input.name] = input.type
                }
            }
            let sortedProperties: [(name: String, type: String)] =
                propertyTypes.keys.sorted().map { (name: $0, type: propertyTypes[$0]!) }

            lines.append(Self.renderInputStruct(access: access, event: event, properties: sortedProperties))
            lines.append(
                Self.renderNotificationEnum(
                    access: access,
                    protocolName: protocolName,
                    event: event,
                    properties: sortedProperties,
                    placeholders: sortedPlaceholders,
                    variablesByName: variablesByName
                ))
        }

        return lines
    }

    private static func renderInputStruct(
        access: String, event: EventNotificationDefinition, properties: [(name: String, type: String)]
    ) -> String {
        var lines = ["\(access) struct \(event.eventName)NotificationInput: Decodable {"]
        for property in properties {
            lines.append("    \(access) let \(property.name): \(property.type)")
        }
        lines.append("")
        let parameterList = properties.map { "\($0.name): \($0.type)" }.joined(separator: ", ")
        lines.append("    \(access) init(\(parameterList)) {")
        for property in properties {
            lines.append("        self.\(property.name) = \(property.name)")
        }
        lines.append("    }")
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private static func renderNotificationEnum(
        access: String,
        protocolName: String,
        event: EventNotificationDefinition,
        properties: [(name: String, type: String)],
        placeholders: [String],
        variablesByName: [String: VariableDefinition]
    ) -> String {
        var lines = ["\(access) enum \(event.eventName)Notification {"]

        // render(input:variables:)
        lines.append(
            "    \(access) static func render(input: \(event.eventName)NotificationInput, variables: some \(protocolName)) async throws -> [RenderedNotification] {")

        if !placeholders.isEmpty {
            // Only String-typed properties can populate the __value seam's [String: String]
            // inputs dictionary — a type: recipients variable's Data-typed eventMetadata (if any
            // property happens to be named that) never participates in text-template resolution.
            lines.append("        let inputs: [String: String] = [")
            for property in properties where property.type == "String" {
                lines.append("            \"\(property.name)\": input.\(property.name),")
            }
            lines.append("        ]")
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

        lines.append("        return [")
        for entry in event.notifications {
            let fieldRecipients: [String] = entry.recipients.compactMap {
                guard case .field(let name) = $0 else { return nil }
                return "input.\(name)"
            }
            let variableRecipients: [String] = entry.recipients.compactMap { source in
                guard case .variable(let variableName) = source, let variable = variablesByName[variableName] else {
                    return nil
                }
                let arguments = variable.inputs.map { "\($0.name): input.\($0.name)" }.joined(separator: ", ")
                return "try await variables.\(Self.lowerCamel(variable.name))(\(arguments))"
            }
            let recipientsExpression: String
            if variableRecipients.isEmpty {
                // Unchanged from before mixed-recipients support existed — keeps every
                // token-free notification.yaml's generated code byte-identical.
                recipientsExpression = "[\(fieldRecipients.joined(separator: ", "))]"
            } else {
                var parts = ["[\(fieldRecipients.joined(separator: ", "))]"]
                parts.append(contentsOf: variableRecipients.map { "(\($0))" })
                recipientsExpression = parts.joined(separator: " + ")
            }
            lines.append("            RenderedNotification(")
            lines.append("                type: NotificationType(rawValue: \"\(entry.type)\")!,")
            lines.append("                recipients: \(recipientsExpression),")
            lines.append("                fields: [")
            for field in entry.fields {
                let escapedTemplate = Self.escapeSwiftStringLiteral(field.template)
                let valuesArgument = placeholders.isEmpty ? "[:]" : "values"
                // `content` fields' handling depends on the entry's resolved `render` value —
                // the trust boundary (trusted template vs. untrusted %placeholder% values) is
                // only visible at this point:
                //   - markdown: Markdown-escape the substituted values, then render the merged
                //     Markdown to an allow-listed HTML subset.
                //   - plaintext: skip Markdown parsing entirely; substitute values verbatim,
                //     with no escaping — there is no markup context for them to escape into.
                // `subject`/`title` are never Markdown-rendered regardless of `render` (e.g. an
                // email subject or inbox heading): always plain substitution, no escaping.
                // See docs/superpowers/specs/2026-09-09-markdown-notification-content-design.md
                // §3-4 and docs/superpowers/specs/2026-09-15-inapp-render-format-design.md §3.
                if field.name == "content", entry.render == .markdown {
                    lines.append(
                        "                    \"\(field.name)\": MarkdownRendering.html(from: try PlaceholderSubstitution.substitute(\"\(escapedTemplate)\", values: \(valuesArgument), escaping: .markdown)),"
                    )
                } else {
                    lines.append(
                        "                    \"\(field.name)\": try PlaceholderSubstitution.substitute(\"\(escapedTemplate)\", values: \(valuesArgument)),"
                    )
                }
            }
            if entry.type == "inApp" {
                // Wire model: inApp carries its resolved render format alongside title/content
                // (mail's render choice is fully resolved into HTML upstream, so mail never
                // gets this field) — see spec §4-5.
                lines.append("                    \"render\": \"\(entry.render.rawValue)\",")
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
