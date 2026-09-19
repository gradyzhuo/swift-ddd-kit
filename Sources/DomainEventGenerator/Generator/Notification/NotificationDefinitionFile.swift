//
//  NotificationDefinitionFile.swift
//  DomainEventGenerator
//
//  Parses `notification.yaml` — the notification-definition framework's per-event
//  recipients + per-channel copy contract.
//  See spec: docs/superpowers/specs/2026-09-07-notification-definition-design.md §4
//

import Foundation
import Yams

/// Whether a notification entry's `content` is authored in Markdown (parsed and rendered to
/// safe HTML) or plaintext (substituted verbatim, no markdown parsing, no escaping). See spec:
/// docs/superpowers/specs/2026-09-15-inapp-render-format-design.md §2-3.
package enum NotificationRenderFormat: String, Equatable, Sendable {
    case markdown
    case plaintext
}

extension NotificationRenderFormat {
    /// The render format a channel entry gets when its `render:` key is omitted — `mail` keeps
    /// today's markdown behavior, `inApp` defaults to the new plaintext behavior. See spec §2.
    package static func defaultFormat(forType type: String) -> NotificationRenderFormat {
        type == "mail" ? .markdown : .plaintext
    }
}

/// One channel entry (`mail`/`inApp`) for a single event, with its fields in the type's
/// canonical schema order (`mail`: subject, content; `inApp`: title, content). `id` is this
/// entry's own identifier, unique among the entries of the same event — used to derive the
/// generated per-entry protocol's name (see `NotificationGenerator`).
package struct NotificationEntry: Equatable {
    package let id: String
    package let type: String
    package let render: NotificationRenderFormat
    package let fields: [(name: String, template: String)]

    package init(
        id: String, type: String, render: NotificationRenderFormat,
        fields: [(name: String, template: String)]
    ) {
        self.id = id
        self.type = type
        self.render = render
        self.fields = fields
    }

    package static func == (lhs: NotificationEntry, rhs: NotificationEntry) -> Bool {
        lhs.id == rhs.id
            && lhs.type == rhs.type
            && lhs.render == rhs.render
            && lhs.fields.count == rhs.fields.count
            && zip(lhs.fields, rhs.fields).allSatisfy { $0.name == $1.name && $0.template == $1.template }
    }
}

/// One event's notification declaration: which event fields fan out to recipients, and the
/// per-channel copy that references `%Placeholder%` tokens resolved against `variables.yaml`.
package struct EventNotificationDefinition: Equatable {
    package let eventName: String
    package let notifications: [NotificationEntry]

    package init(eventName: String, notifications: [NotificationEntry]) {
        self.eventName = eventName
        self.notifications = notifications
    }
}

package enum NotificationParseError: Error, Equatable, Sendable {
    case unknownType(event: String, type: String)
    case duplicateType(event: String, type: String)
    case missingField(event: String, type: String, field: String)
    case extraField(event: String, type: String, field: String)
    case invalidRenderFormat(event: String, type: String, value: String)
    case missingId(event: String, type: String)
    case invalidId(event: String, id: String)
    case duplicateId(event: String, id: String)
    case emptyNotifications(event: String)
}

extension NotificationParseError: CustomStringConvertible {
    package var description: String {
        switch self {
        case .unknownType(let event, let type):
            if type.isEmpty {
                return "event '\(event)': notification entry is missing its `type` key"
            }
            return "event '\(event)': unknown notification type '\(type)' (expected 'mail' or 'inApp')"
        case .duplicateType(let event, let type):
            return "event '\(event)': notification type '\(type)' is declared more than once"
        case .missingField(let event, let type, let field):
            return "event '\(event)': notification type '\(type)' is missing required field '\(field)'"
        case .extraField(let event, let type, let field):
            return "event '\(event)': notification type '\(type)' has unexpected field '\(field)'"
        case .invalidRenderFormat(let event, let type, let value):
            return "event '\(event)': notification type '\(type)' has invalid `render` value '\(value)' (expected 'markdown' or 'plaintext')"
        case .missingId(let event, let type):
            return "event '\(event)': notification type '\(type)' is missing required `id` key"
        case .invalidId(let event, let id):
            return "event '\(event)': id '\(id)' is not a valid id (expected lowercase letters/digits/'-'/'_' , starting with a lowercase letter)"
        case .duplicateId(let event, let id):
            return "event '\(event)': id '\(id)' is declared more than once"
        case .emptyNotifications(let event):
            return "event '\(event)': `notifications` must not be empty"
        }
    }
}

/// Parses `notification.yaml` by walking Yams' `Node` tree directly (mirroring
/// `VariablesParser`), so per-event/per-type error context is available while validating the
/// closed type schemas and preserving `recipients`' declared YAML order.
package enum NotificationDefinitionParser {

    /// Closed field schema per notification type, in canonical (generated-field) order.
    private static let typeSchemas: [String: [String]] = [
        "mail": ["subject", "content"],
        "inApp": ["title", "content"],
    ]

    /// `id:` grammar: a lowercase letter, then lowercase letters/digits/`-`/`_`.
    private static let idRegex: NSRegularExpression = {
        // Safe to force-unwrap: the pattern is a fixed, valid literal.
        try! NSRegularExpression(pattern: "^[a-z][a-z0-9_-]*$")
    }()

    private static func isValidId(_ id: String) -> Bool {
        let range = NSRange(id.startIndex..., in: id)
        return idRegex.firstMatch(in: id, range: range) != nil
    }

    package static func parse(yaml: String) throws -> [EventNotificationDefinition] {
        guard let root = try Yams.compose(yaml: yaml), let mapping = root.mapping else {
            return []
        }

        var definitions: [EventNotificationDefinition] = []

        for (keyNode, valueNode) in mapping {
            let eventName = keyNode.string ?? ""
            try IdentifierValidation.validate(eventName, kind: .eventName)
            let eventMapping = valueNode.mapping

            let notificationsSequence = eventMapping?["notifications"]?.sequence ?? []
            guard !notificationsSequence.isEmpty else {
                throw NotificationParseError.emptyNotifications(event: eventName)
            }

            var notifications: [NotificationEntry] = []
            var seenTypes: Set<String> = []
            var seenIds: Set<String> = []
            for entryNode in notificationsSequence {
                let entryMapping = entryNode.mapping
                let type = entryMapping?["type"]?.string ?? ""

                guard let schemaFields = Self.typeSchemas[type] else {
                    throw NotificationParseError.unknownType(event: eventName, type: type)
                }
                guard seenTypes.insert(type).inserted else {
                    throw NotificationParseError.duplicateType(event: eventName, type: type)
                }

                let id = entryMapping?["id"]?.string ?? ""
                guard !id.isEmpty else {
                    throw NotificationParseError.missingId(event: eventName, type: type)
                }
                guard Self.isValidId(id) else {
                    throw NotificationParseError.invalidId(event: eventName, id: id)
                }
                guard seenIds.insert(id).inserted else {
                    throw NotificationParseError.duplicateId(event: eventName, id: id)
                }

                let allowedKeys = Set(schemaFields).union(["type", "render", "id"])
                if let entryMapping {
                    for (fieldKeyNode, _) in entryMapping {
                        guard let fieldKey = fieldKeyNode.string else { continue }
                        guard allowedKeys.contains(fieldKey) else {
                            throw NotificationParseError.extraField(event: eventName, type: type, field: fieldKey)
                        }
                    }
                }

                let render: NotificationRenderFormat
                if let renderValue = entryMapping?["render"]?.string {
                    guard let parsed = NotificationRenderFormat(rawValue: renderValue) else {
                        throw NotificationParseError.invalidRenderFormat(event: eventName, type: type, value: renderValue)
                    }
                    render = parsed
                } else {
                    render = NotificationRenderFormat.defaultFormat(forType: type)
                }

                var fields: [(name: String, template: String)] = []
                for fieldName in schemaFields {
                    guard let template = entryMapping?[fieldName]?.string else {
                        throw NotificationParseError.missingField(event: eventName, type: type, field: fieldName)
                    }
                    fields.append((name: fieldName, template: template))
                }

                notifications.append(NotificationEntry(id: id, type: type, render: render, fields: fields))
            }

            definitions.append(EventNotificationDefinition(eventName: eventName, notifications: notifications))
        }

        return definitions
    }
}

/// Extracts `%Placeholder%` tokens (grammar v1: `%[A-Za-z0-9_]+%`) from a template string, in
/// first-appearance order, deduplicated.
package enum PlaceholderExtractor {
    private static let tokenRegex: NSRegularExpression = {
        // Safe to force-unwrap: the pattern is a fixed, valid literal.
        try! NSRegularExpression(pattern: "%([A-Za-z0-9_]+)%")
    }()

    package static func placeholders(in template: String) -> [String] {
        let nsTemplate = template as NSString
        let fullRange = NSRange(location: 0, length: nsTemplate.length)
        let matches = tokenRegex.matches(in: template, range: fullRange)

        var seen: Set<String> = []
        var result: [String] = []
        for match in matches {
            guard match.numberOfRanges > 1 else { continue }
            let placeholder = nsTemplate.substring(with: match.range(at: 1))
            if seen.insert(placeholder).inserted {
                result.append(placeholder)
            }
        }
        return result
    }
}
