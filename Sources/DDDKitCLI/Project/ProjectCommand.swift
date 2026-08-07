import ArgumentParser

struct ProjectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "project",
        abstract: "Create and manage swift-ddd-kit projects.",
        subcommands: [
            ProjectCreateCommand.self,
        ]
    )
}
