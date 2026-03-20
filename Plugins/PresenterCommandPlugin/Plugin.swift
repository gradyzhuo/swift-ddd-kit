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

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
          try process.run()
        } catch {
          let stdErr: String?
          if let errorData = try errorPipe.fileHandleForReading.readToEnd() {
            stdErr = String(decoding: errorData, as: UTF8.self)
          } else {
            stdErr = nil
          }
          throw CommandPluginError.generationFailure(
            executable: executableURL.absoluteStringNoScheme,
            arguments: arguments,
            stdErr: stdErr
          )
        }
        process.waitUntilExit()
        
        if process.terminationReason == .exit && process.terminationStatus == 0 {
          return
        }

        let stdErr: String?
        if let errorData = try errorPipe.fileHandleForReading.readToEnd() {
          stdErr = String(decoding: errorData, as: UTF8.self)
        } else {
          stdErr = nil
        }
        throw CommandPluginError.generationFailure(
          executable: executableURL.absoluteStringNoScheme,
          arguments: arguments,
          stdErr: stdErr
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

extension ProjectionModelCommandPlugin: CommandPlugin{
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        try self.performCommand(
          arguments: arguments,
          tool: context.tool,
          pluginWorkDirectoryURL: context.pluginWorkDirectoryURL
        )
    }
}
