//
//  PlaceholderSubstitution.swift
//  TemplateVariables
//
//  The `%token%` substitution engine: one left-to-right pass over a template, replacing each
//  `%Name%` with its value. Values are never re-scanned, so a value containing `%` is inert.
//

import Foundation

public enum PlaceholderSubstitutionError: Error, Equatable {
    case missingValue(placeholder: String)
}

/// The `%token%` substitution engine.
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
