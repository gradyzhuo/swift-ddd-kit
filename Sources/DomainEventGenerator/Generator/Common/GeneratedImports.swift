//
//  GeneratedImports.swift
//  DDDKit
//

/// Modules every generated file imports before the config's own `dependencies`.
/// Generated code only uses DDDCore and EventSourcing types, so it compiles
/// against any `EventStore`, not only KurrentDB.
package enum GeneratedImports {
    package static let event = ["Foundation", "DDDCore", "EventSourcing"]
    package static let eventMapper = ["Foundation", "DDDCore", "EventSourcing"]
    package static let projectionModel = ["Foundation", "DDDCore", "EventSourcing"]
}
