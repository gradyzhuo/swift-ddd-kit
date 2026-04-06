//
//  main.swift
//  DDDKit
//
//  Created by Grady Zhuo on 2026/2/9.
//
import Foundation
import PackagePlugin

enum CommandPluginError: Error {
    case eventDefinitionFileNotFound
    case projectionModelDefinitionFileNotFound
    case configFileNotFound
    case generationFailure(executable: String, arguments: [String], stdErr: String?)
}

extension URL {
  /// Returns `URL.absoluteString` with the `file://` scheme prefix removed
  ///
  /// Note: This method also removes percent-encoded UTF-8 characters
  var absoluteStringNoScheme: String {
    var absoluteString = self.absoluteString.removingPercentEncoding ?? self.absoluteString
    absoluteString.trimPrefix("file://")
    return absoluteString
  }
}

@main
struct ProjectionModelCommandPlugin {

    func performCommand(
      arguments: [String],
      tool: (String) throws -> PluginContext.Tool,
      pluginWorkDirectoryURL: URL
    ) throws {
        let (flagsAndOptions, inputs) = self.splitArgs(arguments)
        print(flagsAndOptions, inputs)
                
        //generated directories target
        let executableURL = try tool("generate").url
        
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
          try process.run()
        } catch {
          throw CommandPluginError.generationFailure(
            executable: executableURL.absoluteStringNoScheme,
            arguments: arguments,
            stdErr: stderrString(from: errorPipe)
          )
        }
        process.waitUntilExit()

        if process.terminationReason == .exit && process.terminationStatus == 0 {
          return
        }

        throw CommandPluginError.generationFailure(
          executable: executableURL.absoluteStringNoScheme,
          arguments: arguments,
          stdErr: stderrString(from: errorPipe)
        )
        
    }
    
    
    private func splitArgs(_ args: [String]) -> (options: [String], inputs: [String]) {
      let inputs: [String]
      let options: [String]

      if let index = args.firstIndex(of: "--") {
        let nextIndex = args.index(after: index)
        inputs = Array(args[nextIndex...])
        options = Array(args[..<index])
      } else {
        options = []
        inputs = args
      }

      return (options, inputs)
    }
}

private func stderrString(from pipe: Pipe) -> String? {
    guard let data = try? pipe.fileHandleForReading.readToEnd(), !data.isEmpty else { return nil }
    return String(decoding: data, as: UTF8.self)
}

extension ProjectionModelCommandPlugin: CommandPlugin{
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        try self.performCommand(
          arguments: arguments,
          tool: context.tool,
          pluginWorkDirectoryURL: context.pluginWorkDirectoryURL
        )
    }
}
