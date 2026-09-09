import Foundation

/// The closed set of notification channels a generated `render()` may produce.
public enum NotificationType: String, Codable, Sendable, CaseIterable {
    case mail
    case inApp
}

/// One rendered notification for a single channel, ready to be flattened into
/// the Published Language event's `payload` (see spec §6).
public struct RenderedNotification: Equatable, Sendable {
    public let type: NotificationType
    public let fields: [String: String]

    public init(type: NotificationType, fields: [String: String]) {
        self.type = type
        self.fields = fields
    }
}

extension RenderedNotification {
    /// Flattens `fields` to the cross-context Published Language payload key convention:
    /// `"{type}.{field}"` (e.g. `["mail.subject": ..., "mail.content": ...]`). See spec §6.
    public var payloadEntries: [String: String] {
        Dictionary(uniqueKeysWithValues: fields.map { field, value in ("\(type.rawValue).\(field)", value) })
    }
}

/// Parses/builds the `"{type}.{field}"` Published Language payload key convention (see spec §6),
/// the inverse of ``RenderedNotification/payloadEntries``.
public enum PayloadKey {
    /// Parses `"{type}.{field}"` back into its type and field.
    ///
    /// - Returns: `nil` when `key` has no `.`, the field half is empty, or the prefix before the
    ///   first `.` isn't a known ``NotificationType``.
    public static func parse(_ key: String) -> (type: NotificationType, field: String)? {
        guard let dotIndex = key.firstIndex(of: ".") else { return nil }
        let typePrefix = String(key[key.startIndex..<dotIndex])
        let field = String(key[key.index(after: dotIndex)...])
        guard !field.isEmpty, let type = NotificationType(rawValue: typePrefix) else { return nil }
        return (type, field)
    }
}

/// Errors thrown by ``PlaceholderSubstitution/substitute(_:values:)``.
public enum PlaceholderSubstitutionError: Error, Equatable {
    case missingValue(placeholder: String)
}

/// The `%token%` substitution engine used by generated `render()` functions.
public enum PlaceholderSubstitution {

    /// Matches placeholder grammar v1: `%[A-Za-z0-9_]+%`.
    private static let tokenRegex: NSRegularExpression = {
        // Safe to force-unwrap: the pattern is a fixed, valid literal.
        try! NSRegularExpression(pattern: "%[A-Za-z0-9_]+%")
    }()

    /// Replaces every `%token%` occurrence in `template` with `values[token]`.
    ///
    /// Performs a single left-to-right pass over the ORIGINAL `template`'s
    /// regex matches, copying the untouched text between matches verbatim and
    /// substituting each match's value as found. Because matches are located
    /// once against the original string, a value that itself contains `%`
    /// (or looks like a token) is never re-substituted. Text outside a match
    /// (including `%%` or `%not a token!%`, whose contents fall outside
    /// `[A-Za-z0-9_]`) passes through unchanged.
    ///
    /// - Throws: ``PlaceholderSubstitutionError/missingValue(placeholder:)``
    ///   if a matched token has no corresponding entry in `values`.
    public static func substitute(_ template: String, values: [String: String]) throws -> String {
        let nsTemplate = template as NSString
        let fullRange = NSRange(location: 0, length: nsTemplate.length)
        let matches = tokenRegex.matches(in: template, range: fullRange)

        guard !matches.isEmpty else {
            return template
        }

        var result = ""
        result.reserveCapacity(nsTemplate.length)
        var cursor = 0

        for match in matches {
            let matchRange = match.range
            // Copy the verbatim text preceding this match.
            if matchRange.location > cursor {
                result += nsTemplate.substring(with: NSRange(location: cursor, length: matchRange.location - cursor))
            }

            // Extract the placeholder name (strip the surrounding `%`).
            let tokenText = nsTemplate.substring(with: matchRange)
            let placeholder = String(tokenText.dropFirst().dropLast())

            guard let value = values[placeholder] else {
                throw PlaceholderSubstitutionError.missingValue(placeholder: placeholder)
            }

            result += value
            cursor = matchRange.location + matchRange.length
        }

        // Copy any trailing verbatim text after the last match.
        if cursor < nsTemplate.length {
            result += nsTemplate.substring(with: NSRange(location: cursor, length: nsTemplate.length - cursor))
        }

        return result
    }
}

/// How ``PlaceholderSubstitution/substitute(_:values:escaping:)`` treats each `values` entry
/// before substituting it into the template.
public enum PlaceholderEscaping: Sendable {
    /// Values are substituted verbatim (today's behavior — see `substitute(_:values:)`).
    case none
    /// Values are Markdown-escaped before substitution, so a value like `[x](y)` or `<script>`
    /// is inert literal text in the resulting Markdown rather than link/tag syntax. Use this for
    /// fields whose substituted result is subsequently rendered with ``MarkdownRendering``.
    case markdown
}

extension PlaceholderSubstitution {

    /// Like ``substitute(_:values:)``, but first escapes every value in `values` per `escaping`.
    ///
    /// The TEMPLATE itself is always trusted, author-written Markdown and is never escaped —
    /// only the substituted VALUES are, so untrusted data cannot inject Markdown syntax (or,
    /// once rendered by ``MarkdownRendering``, HTML markup). See
    /// docs/superpowers/specs/2026-09-09-markdown-notification-content-design.md §3.
    public static func substitute(_ template: String, values: [String: String], escaping: PlaceholderEscaping) throws -> String {
        switch escaping {
        case .none:
            return try substitute(template, values: values)
        case .markdown:
            return try substitute(template, values: values.mapValues(escapeMarkdown))
        }
    }

    /// Backslash-escapes every Markdown-significant character in `value` so a Markdown parser
    /// treats it as literal text, never as syntax (emphasis, links, headings, lists, code
    /// spans, HTML tags, ...).
    static func escapeMarkdown(_ value: String) -> String {
        // CommonMark's full punctuation-escape set, plus `<`/`>` (HTML tag delimiters) since the
        // substituted Markdown is subsequently rendered to HTML — an unescaped `<script>` must
        // not reach the parser as a raw-HTML node's literal delimiter-free text.
        let escapable: Set<Character> = [
            "\\", "`", "*", "_", "{", "}", "[", "]", "(", ")", "#", "+", "-", ".", "!", "<", ">",
        ]
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            if escapable.contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }
}
