//
//  Plugin.swift
//  DDDKit
//
//  Build-tool plugin: generates per-event notification swift files from a
//  target's `notification.yaml` + `variables.yaml` + `notification-generator-config.yaml`.
//  See spec: docs/superpowers/specs/2026-09-07-notification-definition-design.md §4
//

import Foundation
import PackagePlugin

enum NotificationGeneratorPluginError: Error {
    case notificationDefinitionFileNotFound(targetName: String)
    case variablesDefinitionFileNotFound(targetName: String)
    case configFileNotFound(targetName: String)
}

extension NotificationGeneratorPluginError: CustomStringConvertible {
    var description: String {
        switch self {
        case .notificationDefinitionFileNotFound(let targetName):
            return "target '\(targetName)': notification.yaml not found — add it to the target's sources"
        case .variablesDefinitionFileNotFound(let targetName):
            return "target '\(targetName)': variables.yaml not found — add it to the target's sources"
        case .configFileNotFound(let targetName):
            return "target '\(targetName)': notification-generator-config.yaml not found — add it to the target's sources"
        }
    }
}

@main struct NotificationGeneratorPlugin {
    func createBuildCommands(
        pluginWorkDirectory: URL,
        tool: (String) throws -> URL,
        sourceFiles: FileList,
        targetName: String
    ) throws -> [Command] {
        guard let notificationSource = (sourceFiles.first { $0.url.lastPathComponent == "notification.yaml" }) else {
            throw NotificationGeneratorPluginError.notificationDefinitionFileNotFound(targetName: targetName)
        }

        guard let variablesSource = (sourceFiles.first { $0.url.lastPathComponent == "variables.yaml" }) else {
            throw NotificationGeneratorPluginError.variablesDefinitionFileNotFound(targetName: targetName)
        }

        guard let configSource = (sourceFiles.first { $0.url.lastPathComponent == "notification-generator-config.yaml" }) else {
            throw NotificationGeneratorPluginError.configFileNotFound(targetName: targetName)
        }

        // generated directory target
        let generatedTargetDirectory = pluginWorkDirectory.appending(component: "generated", directoryHint: .isDirectory)

        // generated file target
        let generatedNotificationSource = generatedTargetDirectory.appending(path: "generated-notification.swift")

        return [
            try .buildCommand(displayName: "Notification Generating...\(notificationSource.url.path())", executable: tool("generate"), arguments: [
                "notification",
                "--variables", variablesSource.url.path(),
                "--generator-configuration", configSource.url.path(),
                "--output", generatedNotificationSource.path(),
                notificationSource.url.path()
            ], inputFiles: [
                notificationSource.url,
                variablesSource.url,
                configSource.url
            ], outputFiles: [
                generatedNotificationSource
            ])
        ]
    }
}

extension NotificationGeneratorPlugin: BuildToolPlugin {
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

extension NotificationGeneratorPlugin: XcodeBuildToolPlugin {
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
