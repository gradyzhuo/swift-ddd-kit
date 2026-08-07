//
//  Plugin.swift
//  DDDKitCreatePlugin
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

/// `swift package dddkit-create <name> [options...]` — runs `dddkit project create`
/// with the current working directory as the scaffold's parent directory, so a
/// package that already depends on swift-ddd-kit can generate a sibling starter
/// project without installing `dddkit` separately.
@main
struct DDDKitCreatePlugin {

    func performCommand(
        arguments: [String],
        tool: (String) throws -> PluginContext.Tool
    ) throws {
        let executableURL = try tool("DDDKitCLI").url

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["project", "create"] + arguments

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

extension DDDKitCreatePlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        try self.performCommand(
            arguments: arguments,
            tool: context.tool
        )
    }
}
