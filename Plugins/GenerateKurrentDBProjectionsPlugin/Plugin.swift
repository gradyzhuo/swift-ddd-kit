//
//  Plugin.swift
//  GenerateKurrentDBProjectionsPlugin
//
//  Created by Grady Zhuo on 2026/4/6.
//
import Foundation
import PackagePlugin

enum CommandPluginError: Error {
    case generationFailure(executable: String, arguments: [String], stdErr: String?)
}

extension URL {
    var absoluteStringNoScheme: String {
        var absoluteString = self.absoluteString.removingPercentEncoding ?? self.absoluteString
        absoluteString.trimPrefix("file://")
        return absoluteString
    }
}

@main
struct GenerateKurrentDBProjectionsPlugin {

    func performCommand(
        arguments: [String],
        tool: (String) throws -> PluginContext.Tool
    ) throws {
        let executableURL = try tool("generate").url

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["kurrentdb-projection"] + arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            let stdErr = stderrString(from: errorPipe)
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

        throw CommandPluginError.generationFailure(
            executable: executableURL.absoluteStringNoScheme,
            arguments: arguments,
            stdErr: stderrString(from: errorPipe)
        )
    }
}

private func stderrString(from pipe: Pipe) -> String? {
    guard let data = try? pipe.fileHandleForReading.readToEnd(), !data.isEmpty else { return nil }
    return String(decoding: data, as: UTF8.self)
}

extension GenerateKurrentDBProjectionsPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        try self.performCommand(
            arguments: arguments,
            tool: context.tool
        )
    }
}
