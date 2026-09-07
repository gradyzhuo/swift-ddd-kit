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

/// One channel entry (`mail`/`inApp`) for a single event, with its fields in the type's
/// canonical schema order (`mail`: subject, content; `inApp`: title, content).
package struct NotificationEntry: Equatable {
    package let type: String
    package let fields: [(name: String, template: String)]

    package init(type: String, fields: [(name: String, template: String)]) {
        self.type = type
        self.fields = fields
    }

    package static func == (lhs: NotificationEntry, rhs: NotificationEntry) -> Bool {
        lhs.type == rhs.type
            && lhs.fields.count == rhs.fields.count
            && zip(lhs.fields, rhs.fields).allSatisfy { $0.name == $1.name && $0.template == $1.template }
    }
}

/// One event's notification declaration: which event fields fan out to recipients, and the
/// per-channel copy that references `%Placeholder%` tokens resolved against `variables.yaml`.
package struct EventNotificationDefinition: Equatable {
    package let eventName: String
    package let recipients: [String]
    package let notifications: [NotificationEntry]

    package init(eventName: String, recipients: [String], notifications: [NotificationEntry]) {
        self.eventName = eventName
        self.recipients = recipients
        self.notifications = notifications
    }
}

package enum NotificationParseError: Error, Equatable, Sendable {
    case unknownType(event: String, type: String)
    case missingField(event: String, type: String, field: String)
    case extraField(event: String, type: String, field: String)
    case emptyRecipients(event: String)
    case emptyNotifications(event: String)
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

    package static func parse(yaml: String) throws -> [EventNotificationDefinition] {
        guard let root = try Yams.compose(yaml: yaml), let mapping = root.mapping else {
            return []
        }

        var definitions: [EventNotificationDefinition] = []

        for (keyNode, valueNode) in mapping {
            let eventName = keyNode.string ?? ""
            let eventMapping = valueNode.mapping

            let recipients: [String] = eventMapping?["recipients"]?.sequence?.compactMap { $0.string } ?? []
            guard !recipients.isEmpty else {
                throw NotificationParseError.emptyRecipients(event: eventName)
            }

            let notificationsSequence = eventMapping?["notifications"]?.sequence ?? []
            guard !notificationsSequence.isEmpty else {
                throw NotificationParseError.emptyNotifications(event: eventName)
            }

            var notifications: [NotificationEntry] = []
            for entryNode in notificationsSequence {
                let entryMapping = entryNode.mapping
                let type = entryMapping?["type"]?.string ?? ""

                guard let schemaFields = Self.typeSchemas[type] else {
                    throw NotificationParseError.unknownType(event: eventName, type: type)
                }

                let allowedKeys = Set(schemaFields).union(["type"])
                if let entryMapping {
                    for (fieldKeyNode, _) in entryMapping {
                        guard let fieldKey = fieldKeyNode.string else { continue }
                        guard allowedKeys.contains(fieldKey) else {
                            throw NotificationParseError.extraField(event: eventName, type: type, field: fieldKey)
                        }
                    }
                }

                var fields: [(name: String, template: String)] = []
                for fieldName in schemaFields {
                    guard let template = entryMapping?[fieldName]?.string else {
                        throw NotificationParseError.missingField(event: eventName, type: type, field: fieldName)
                    }
                    fields.append((name: fieldName, template: template))
                }

                notifications.append(NotificationEntry(type: type, fields: fields))
            }

            definitions.append(
                EventNotificationDefinition(eventName: eventName, recipients: recipients, notifications: notifications))
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
