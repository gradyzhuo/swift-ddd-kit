import ArgumentParser
import Foundation

struct ProjectCreateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Scaffold a new swift-ddd-kit starter project (aggregate + usecases + KurrentDB wiring).",
        discussion: """
            Generates a runnable DDD / Event-Sourcing starter: one aggregate with \
            Create / Rename / Delete use cases, a read-side projector, KurrentDB \
            wiring, and aggregate-level unit tests. See the generated README.md \
            for prerequisites and next steps.
            """
    )

    @Argument(help: "The project name, e.g. OrderContext.")
    var name: String

    @Option(
        name: .customLong("aggregate"),
        help: "The aggregate root name, e.g. Order. Defaults to the project name with a trailing 'Context' dropped."
    )
    var aggregateName: String?

    @Option(
        name: .shortAndLong,
        help: "Directory to create the project in. Defaults to ./<ProjectName>."
    )
    var output: String?

    @Option(
        name: .customLong("kit-version"),
        help: "swift-ddd-kit version requirement for the generated Package.swift."
    )
    var kitVersion: String = "1.0.0"

    @Flag(
        name: .shortAndLong,
        help: "Overwrite the output directory if it already exists and is non-empty."
    )
    var force: Bool = false

    func run() throws {
        let projectWords = NameConvention.words(from: name)
        guard !projectWords.isEmpty else {
            throw ValidationError("'\(name)' has no letters or numbers usable as a Swift identifier.")
        }
        let projectName = NameConvention.pascalCase(words: projectWords)

        let aggregateWords: [String]
        if let aggregateName {
            aggregateWords = NameConvention.words(from: aggregateName)
            guard !aggregateWords.isEmpty else {
                throw ValidationError("'\(aggregateName)' has no letters or numbers usable as a Swift identifier.")
            }
        } else {
            aggregateWords = NameConvention.defaultAggregateWords(fromProjectWords: projectWords)
        }
        let resolvedAggregateName = NameConvention.pascalCase(words: aggregateWords)

        let kitDependencyLine = ".package(url: \"https://github.com/gradyzhuo/swift-ddd-kit.git\", from: \"\(kitVersion)\"),"

        let context = ProjectContext(
            projectName: projectName,
            aggregateName: resolvedAggregateName,
            kitDependencyLine: kitDependencyLine
        )

        let fileManager = FileManager.default
        let outputPath = output ?? projectName
        let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: outputDirectory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ValidationError("'\(outputDirectory.path)' exists and is not a directory.")
            }
            let existingContents = try fileManager.contentsOfDirectory(atPath: outputDirectory.path)
            if !existingContents.isEmpty && !force {
                throw ValidationError(
                    "'\(outputDirectory.path)' already exists and is not empty. Pass --force to overwrite."
                )
            }
        }

        let files = ProjectTemplate.files(for: context)
        try ScaffoldWriter.write(files, to: outputDirectory)

        print("""
            Created \(context.projectName) at \(outputDirectory.path)

            Aggregate: \(context.aggregateName)  (target: \(context.aggregateTarget))
            App:       \(context.appTarget)

            Next steps:
              cd \(outputDirectory.path)
              swift build
              # start KurrentDB locally (see README.md), then:
              swift run \(context.appTarget)
              swift test
            """)
    }
}
