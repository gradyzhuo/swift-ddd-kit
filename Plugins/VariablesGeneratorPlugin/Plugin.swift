//
//  Plugin.swift
//  DDDKit
//
//  Build-tool plugin: generates a variables protocol swift file from a
//  target's `variables.yaml` + `notification-generator-config.yaml`.
//  See spec: docs/superpowers/specs/2026-09-07-notification-definition-design.md §3
//

import Foundation
import PackagePlugin

enum VariablesGeneratorPluginError: Error {
    case variablesDefinitionFileNotFound
    case configFileNotFound
}

@main struct VariablesGeneratorPlugin {
    func createBuildCommands(
        pluginWorkDirectory: URL,
        tool: (String) throws -> URL,
        sourceFiles: FileList,
        targetName: String
    ) throws -> [Command] {
        guard let variablesSource = (sourceFiles.first { $0.url.lastPathComponent == "variables.yaml" }) else {
            throw VariablesGeneratorPluginError.variablesDefinitionFileNotFound
        }

        guard let configSource = (sourceFiles.first { $0.url.lastPathComponent == "notification-generator-config.yaml" }) else {
            throw VariablesGeneratorPluginError.configFileNotFound
        }

        // generated directory target
        let generatedTargetDirectory = pluginWorkDirectory.appending(component: "generated", directoryHint: .isDirectory)

        // generated file target
        let generatedVariablesSource = generatedTargetDirectory.appending(path: "generated-variables.swift")

        return [
            try .buildCommand(displayName: "Variables Generating...\(variablesSource.url.path())", executable: tool("generate"), arguments: [
                "variables",
                "--generator-configuration", configSource.url.path(),
                "--output", generatedVariablesSource.path(),
                variablesSource.url.path()
            ], inputFiles: [
                variablesSource.url,
                configSource.url
            ], outputFiles: [
                generatedVariablesSource
            ])
        ]
    }
}

extension VariablesGeneratorPlugin: BuildToolPlugin {
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

extension VariablesGeneratorPlugin: XcodeBuildToolPlugin {
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
