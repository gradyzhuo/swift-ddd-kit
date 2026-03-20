//
//  AggregateHelperGenerator.swift
//  DDDKit
//
//  Created by Grady Zhuo on 2025/2/12.
//

import Foundation
import Yams

package struct ProjectionModelGenerator {
    package let aggregateRootGenerator: AggregateRootGenerator
    package let projectorGenerator: ProjectorGenerator
    
    package init(projectionModelYamlFileURL: URL, aggregateRootName: String, aggregateEventsYamlFileURL: URL) throws {
        self.aggregateRootGenerator = try .init(aggregateRootName: aggregateRootName, aggregateEventsYamlFileURL: aggregateEventsYamlFileURL)
        self.projectorGenerator = try ProjectorGenerator(projectionModelYamlFileURL: projectionModelYamlFileURL)
    }
    
    
    package func render(accessLevel: AccessLevel) -> [String] {
        var lines: [String] = []
        lines.append(contentsOf: aggregateRootGenerator.render(accessLevel: accessLevel))
        lines.append(contentsOf: projectorGenerator.render(accessLevel: accessLevel))
        return lines
    }
}


enum ProjectionModelGeneratorError: Error{
    case invalidCreatedEvent
}
