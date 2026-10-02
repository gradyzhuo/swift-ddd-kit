//
//  TemplateAccessLevel.swift
//  TemplateVariablesDefinition
//

/// Access level applied to generated declarations.
public enum TemplateAccessLevel: String, Codable, Sendable {
    case `internal` = "internal"
    case `public` = "public"
    case `package` = "package"
}
