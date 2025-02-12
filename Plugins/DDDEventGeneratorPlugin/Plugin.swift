//
//  Plugin.swift
//  DDDKit
//
//  Created by 卓俊諺 on 2025/2/11.
//

import Foundation
import PackagePlugin

enum PluginError: Error {
    case inputNotFound
    case configNotFound
}

@main struct DDDEventGeneratorPlugin {
    func createBuildCommands(
        pluginWorkDirectory: URL,
        tool: (String) throws -> URL,
        sourceFiles: FileList,
        targetName: String
    ) throws -> [Command] {
        guard let inputSource = (sourceFiles.first{ $0.url.lastPathComponent == "event.yaml" }) else {
            throw PluginError.inputNotFound
        }
        
        guard let configSource = (sourceFiles.first{ $0.url.lastPathComponent == "event-generator-config.yaml" }) else {
            throw PluginError.configNotFound
        }
        
        let generatedEventsSource = pluginWorkDirectory.appending(path: "generated-event.swift")
        let generatedEventMapperSource = pluginWorkDirectory.appending(path: "generated-event-mapper.swift")
    
        return [
            try .buildCommand(displayName: "Event Generating...\(inputSource.url.path())", executable: tool("generate"), arguments: [
                "event",
                "--configuration", "\(configSource.url.path())",
                "--output", "\(generatedEventsSource.path())",
                "\(inputSource.url.path())"
            ], inputFiles: [
                inputSource.url
            ], outputFiles: [
                generatedEventsSource
            ]),
            try .buildCommand(displayName: "EventMapper Generating...\(inputSource.url.path())", executable: tool("generate"), arguments: [
                "event-mapper",
                "--configuration", "\(configSource.url.path())",
                "--output", "\(generatedEventMapperSource.path())",
                "\(inputSource.url.path())"
            ], inputFiles: [
                inputSource.url
            ], outputFiles: [
                generatedEventMapperSource
            ])
        ]
    }
}

extension DDDEventGeneratorPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let swiftTarget = target as? SwiftSourceModuleTarget else {
            return []
        }
    
        return try createBuildCommands(
            pluginWorkDirectory: context.pluginWorkDirectoryURL,
            tool: {
                try context.tool(named: $0).url
            },
            sourceFiles: swiftTarget.sourceFiles,
            targetName: target.name
        )
    
    }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension DDDEventGeneratorPlugin: XcodeBuildToolPlugin {
    func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws -> [Command] {
        try createBuildCommands(
            pluginWorkDirectory: context.pluginWorkDirectoryURL,
            tool: {
                try context.tool(named: $0).url
            },
            sourceFiles: target.inputFiles,
            targetName: target.displayName
        )
    }
}
#endif

