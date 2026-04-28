//
//  EventFilterGenerator.swift
//  DomainEventGenerator
//
//  Renders a concrete `EventTypeFilter` struct for one projection model.
//  Output goes into `generated-event-filter.swift` (sibling to event mapper output).
//  See spec: docs/superpowers/specs/2026-04-28-event-type-filter-design.md
//

import Foundation

package struct EventFilterGenerator {
    let modelName: String
    let eventNames: [String]

    package init(modelName: String, eventNames: [String]) {
        self.modelName = modelName
        self.eventNames = eventNames
    }

    package func render(accessLevel: AccessLevel) -> [String] {
        var lines: [String] = []

        lines.append("""
\(accessLevel.rawValue) struct \(modelName)EventFilter: EventTypeFilter {

    \(accessLevel.rawValue) init() {}

    \(accessLevel.rawValue) func handles(eventType: String) -> Bool {
        switch eventType {
""")

        if !eventNames.isEmpty {
            let cases = eventNames.map { "\"\($0)\"" }.joined(separator: ", ")
            lines.append("""
        case \(cases):
            return true
""")
        }

        lines.append("""
        default:
            return false
        }
    }
}
""")
        return lines
    }
}
