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


@main
struct DomainEventCommandPlugin: CommandPlugin {
  func performCommand(
    context: PluginContext,
    arguments: [String]
  ) throws {

    let generatorTool = try context.tool(named: "generate")

    // Extract the target arguments (if there are none, assume all).
    print("arguments:", arguments)
      
    var argExtractor = ArgumentExtractor(arguments)
    let targetNames = argExtractor.extractOption(named: "target")
    let targets = targetNames.isEmpty
      ? context.package.targets
      : try context.package.targets(named: targetNames)

//      print("target:", targets)
    
    // Iterate over the provided targets to format.
    for target in targets {
      // Skip any type of target that doesn't have
      // source files.
      // Note: This could instead emit a warning or error.
        
        print("target:", target)
        
//      guard let target = target.sourceModule else { continue }
//      guard let inputSource = (target.sourceFiles.first{ $0.url.lastPathComponent == "event.yaml" }) else {
//          throw PluginError.eventDefinitionFileNotFound
//      }
//        guard let configSource = (target.sourceFiles.first{ $0.url.lastPathComponent == "event-generator-config.yaml" }) else {
//            throw PluginError.configFileNotFound
//        }
//        
//    
//        
//      // Invoke `sometool` on the target directory, passing
//      // a configuration file from the package directory.
//      let sometoolExec = generatorTool.url
//        
//      var packageDirectorURL = context.package.directoryURL
//        
//        packageDirectorURL.append(component: target.name)
//      let sometoolArgs = [
//        "event",
//        "--configuration", "\(configSource.url.path())",
//        "--output", "\(generatedEventsSource.path())",
//        "\(inputSource.url.path())"
//      ]
//      let process = try Process.run(sometoolExec,
//                                    arguments: sometoolArgs)
//      process.waitUntilExit()
    }
  }
}

//@main struct DomainEventGeneratorPlugin {
//    func createBuildCommands(
//        pluginWorkDirectory: URL,
//        tool: (String) throws -> URL,
//        sourceFiles: FileList,
//        targetName: String
//    ) throws -> [Command] {
//        guard let inputSource = (sourceFiles.first{ $0.url.lastPathComponent == "event.yaml" }) else {
//            throw PluginError.eventDefinitionFileNotFound
//        }
//        
//        guard let configSource = (sourceFiles.first{ $0.url.lastPathComponent == "event-generator-config.yaml" }) else {
//            throw PluginError.configFileNotFound
//        }
//        
//        //generated directories target
//        let generatedTargetDirectory = pluginWorkDirectory.appending(component: "generated", directoryHint: .isDirectory)
//
//        //generated files target
//        let generatedEventsSource = generatedTargetDirectory.appending(path: "generated-event.swift")
//    
//        return [
//            try .buildCommand(displayName: "Event Generating...\(inputSource.url.path())", executable: tool("generate"), arguments: [
//                "event",
//                "--configuration", "\(configSource.url.path())",
//                "--output", "\(generatedEventsSource.path())",
//                "\(inputSource.url.path())"
//            ], inputFiles: [
//                inputSource.url
//            ], outputFiles: [
//                generatedEventsSource
//            ])
//        ]
//    }
//}
//
//extension DomainEventGeneratorPlugin: BuildToolPlugin {
//    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
//        guard let swiftTarget = target as? SwiftSourceModuleTarget else {
//            return []
//        }
//    
//        return try createBuildCommands(
//            pluginWorkDirectory: context.pluginWorkDirectoryURL,
//            tool: {
//                try context.tool(named: $0).url
//            },
//            sourceFiles: swiftTarget.sourceFiles,
//            targetName: target.name
//        )
//    
//    }
//}
//
//#if canImport(XcodeProjectPlugin)
//import XcodeProjectPlugin
//
//extension DomainEventGeneratorPlugin: XcodeBuildToolPlugin {
//    func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws -> [Command] {
//        try createBuildCommands(
//            pluginWorkDirectory: context.pluginWorkDirectoryURL,
//            tool: {
//                try context.tool(named: $0).url
//            },
//            sourceFiles: target.inputFiles,
//            targetName: target.displayName
//        )
//    }
//}
//#endif
//
