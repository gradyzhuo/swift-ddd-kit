//
//  IdentifierValidation.swift
//  DomainEventGenerator
//
//  Shared identifier-safety checks for names the notification-definition generators emit
//  verbatim (or lowerCamel-transformed) as Swift source identifiers: event names, recipient
//  field names, variable names (as their generated method name), input names, and
//  placeholder-derived local `let` names.
//  See spec: docs/superpowers/specs/2026-09-07-notification-definition-design.md §4
//

import Foundation

/// What kind of declared name failed validation — used only to make
/// ``IdentifierValidationError`` messages readable.
package enum IdentifierKind: String, Sendable, Equatable {
    case eventName = "event name"
    case recipient = "recipient"
    case variableName = "variable"
    case inputName = "input"
    case placeholder = "placeholder"
}

package enum IdentifierValidationError: Error, Equatable, Sendable {
    /// `name` is always the source-level name as declared in YAML — never the
    /// lowerCamel-transformed identifier, even when that's what actually failed validation
    /// (``IdentifierKind/variableName`` and ``IdentifierKind/placeholder``).
    case invalidIdentifier(kind: IdentifierKind, name: String)
    /// Two distinct placeholders lowerCamel to the same generated local `let` name.
    case identifierCollision(a: String, b: String)
}

extension IdentifierValidationError: CustomStringConvertible {
    package var description: String {
        switch self {
        case .invalidIdentifier(let kind, let name):
            switch kind {
            case .placeholder:
                return "placeholder '%\(name)%' does not produce a valid Swift local name " +
                    "('\(IdentifierValidation.lowerCamel(name))') — rename it"
            case .variableName:
                return "variable '\(name)' does not produce a valid Swift method name " +
                    "('\(IdentifierValidation.lowerCamel(name))') — rename it"
            case .eventName, .recipient, .inputName:
                return "\(kind.rawValue) '\(name)' is not a valid Swift identifier"
            }
        case .identifierCollision(let a, let b):
            return "placeholders '%\(a)%' and '%\(b)%' both produce the local name " +
                "'\(IdentifierValidation.lowerCamel(a))' — rename one"
        }
    }
}

/// Shared identifier-safety checks: does a name parse as a Swift identifier, and is it reserved
/// (a Swift keyword, or a name this generator's emitted code already declares for its own use).
package enum IdentifierValidation {

    /// Swift keywords that cannot be used as a bare identifier, plus `inputs`/`values` — the
    /// local names `NotificationGenerator`'s emitted `render()` always declares, so a
    /// placeholder or variable lowerCamel-ing to one of them would collide with the generator's
    /// own code.
    package static let reservedIdentifiers: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import",
        "init", "inout", "internal", "let", "open", "operator", "private", "protocol", "public",
        "rethrows", "static", "struct", "subscript", "typealias", "var",
        "break", "case", "continue", "default", "defer", "do", "else", "fallthrough", "for", "guard",
        "if", "in", "repeat", "return", "switch", "where", "while",
        "as", "Any", "catch", "false", "is", "nil", "self", "Self", "super", "throw", "throws", "true", "try",
        "_",
        "inputs", "values",
    ]

    /// First character letter/underscore, remaining characters alphanumeric/underscore.
    package static func isValidSwiftIdentifier(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// `first.lowercased() + rest` — the transform every generated method/local name applies to
    /// a declared name (variable names, placeholders).
    package static func lowerCamel(_ name: String) -> String {
        guard let first = name.first else { return name }
        return first.lowercased() + name.dropFirst()
    }

    /// Validates `name` verbatim — for names emitted as declared (event names, recipients,
    /// input names).
    package static func validate(_ name: String, kind: IdentifierKind) throws {
        guard isValidSwiftIdentifier(name), !reservedIdentifiers.contains(name) else {
            throw IdentifierValidationError.invalidIdentifier(kind: kind, name: name)
        }
    }

    /// Validates `lowerCamel(name)` — for names whose generated identifier is lowerCamel-cased
    /// (variable names → method names, placeholders → local `let` names). The thrown error still
    /// reports the original, untransformed `name`.
    package static func validateLowerCamel(_ name: String, kind: IdentifierKind) throws {
        let transformed = lowerCamel(name)
        guard isValidSwiftIdentifier(transformed), !reservedIdentifiers.contains(transformed) else {
            throw IdentifierValidationError.invalidIdentifier(kind: kind, name: name)
        }
    }
}
