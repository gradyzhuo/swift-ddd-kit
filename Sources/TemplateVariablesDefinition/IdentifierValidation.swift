//
//  IdentifierValidation.swift
//  TemplateVariablesDefinition
//
//  Identifier-safety checks for names `variables.yaml` declares and the variables generator emits
//  as Swift identifiers: variable names (lowerCamel → method names) and input names (verbatim →
//  parameter and local names). Downstream generators that emit more code around these names
//  reuse `swiftKeywords`, `isValidSwiftIdentifier` and `lowerCamel` with their own reserved set.
//

import Foundation

public enum IdentifierKind: String, Sendable, Equatable {
    case variableName = "variable"
    case inputName = "input"
}

public enum IdentifierValidationError: Error, Equatable, Sendable {
    /// `name` is always the source-level name as declared in YAML — never the lowerCamel form.
    case invalidIdentifier(kind: IdentifierKind, name: String)
}

extension IdentifierValidationError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidIdentifier(.variableName, let name):
            return "variable '\(name)' does not produce a valid Swift method name " +
                "('\(IdentifierValidation.lowerCamel(name))') — rename it"
        case .invalidIdentifier(.inputName, let name):
            return "input '\(name)' is not a valid Swift identifier"
        }
    }
}

public enum IdentifierValidation {

    /// Swift keywords that cannot be used as a bare identifier, plus `_`.
    public static let swiftKeywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import",
        "init", "inout", "internal", "let", "open", "operator", "private", "protocol", "public",
        "rethrows", "static", "struct", "subscript", "typealias", "var",
        "break", "case", "continue", "default", "defer", "do", "else", "fallthrough", "for", "guard",
        "if", "in", "repeat", "return", "switch", "where", "while",
        "as", "Any", "catch", "false", "is", "nil", "self", "Self", "super", "throw", "throws", "true", "try",
        "_",
    ]

    /// Names the variables generator cannot accept: keywords, plus `inputs` — the parameter name
    /// of the generated `__value(of:inputs:)` seam, which a same-named local would shadow.
    public static let reservedIdentifiers: Set<String> = swiftKeywords.union(["inputs"])

    /// First character letter/underscore, remaining characters alphanumeric/underscore.
    public static func isValidSwiftIdentifier(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// `first.lowercased() + rest` — the transform applied to a declared name to get its
    /// generated method or local name.
    public static func lowerCamel(_ name: String) -> String {
        guard let first = name.first else { return name }
        return first.lowercased() + name.dropFirst()
    }

    /// Validates `name` verbatim (input names).
    public static func validate(_ name: String, kind: IdentifierKind) throws {
        guard isValidSwiftIdentifier(name), !reservedIdentifiers.contains(name) else {
            throw IdentifierValidationError.invalidIdentifier(kind: kind, name: name)
        }
    }

    /// Validates `lowerCamel(name)` (variable names). The error reports the original `name`.
    public static func validateLowerCamel(_ name: String, kind: IdentifierKind) throws {
        let transformed = lowerCamel(name)
        guard isValidSwiftIdentifier(transformed), !reservedIdentifiers.contains(transformed) else {
            throw IdentifierValidationError.invalidIdentifier(kind: kind, name: name)
        }
    }
}
