import Foundation

/// A single generated file: a path relative to the project root, and its content.
struct ScaffoldFile {
    let path: String
    let content: String
}

enum ScaffoldWriter {
    /// Writes every file under `directory`, creating intermediate directories as needed.
    static func write(_ files: [ScaffoldFile], to directory: URL) throws {
        let fileManager = FileManager.default
        for file in files {
            let fileURL = directory.appendingPathComponent(file.path)
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try file.content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }
}
