import ArgumentParser

@main
struct DDDKitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dddkit",
        abstract: "Command line tool for swift-ddd-kit — scaffolds and manages DDD/Event-Sourcing projects.",
        subcommands: [
            ProjectCommand.self,
        ]
    )
}
