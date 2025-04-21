//
//  Plugin.swift
//  DDDKit
//
//  Created by 卓俊諺 on 2025/2/11.
//

import Foundation
import PackagePlugin

enum PluginError: Error {
    case eventDefinitionFileNotFound
    case configFileNotFound
}

@main struct DomainEventGeneratorPlugin {
    func createBuildCommands(
        pluginWorkDirectory: URL,
        tool: (String) throws -> URL,
        sourceFiles: FileList,
        targetName: String
    ) throws -> [Command] {
        guard let inputSource = (sourceFiles.first{ $0.url.lastPathComponent == "event.yaml" }) else {
            throw PluginError.eventDefinitionFileNotFound
        }
        
        guard let configSource = (sourceFiles.first{ $0.url.lastPathComponent == "event-generator-config.yaml" }) else {
            throw PluginError.configFileNotFound
        }
        
        //generated directories target
        let generatedTargetDirectory = pluginWorkDirectory.appending(component: "generated", directoryHint: .isDirectory)

        //generated files target
        let generatedEventsSource = generatedTargetDirectory.appending(path: "generated-event.swift")
    
        return [
            try .prebuildCommand(
                displayName: "Event Generating...\(inputSource.url.path())",
                executable: tool("generate"),
                arguments: [
                    "event",
                    "--configuration", "\(configSource.url.path())",
                    "--output", "\(generatedEventsSource.path())",
                    "\(inputSource.url.path())"
                ],
                outputFilesDirectory: generatedTargetDirectory)
            
        ]
    }
}

extension DomainEventGeneratorPlugin: BuildToolPlugin {
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

extension DomainEventGeneratorPlugin: XcodeBuildToolPlugin {
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

