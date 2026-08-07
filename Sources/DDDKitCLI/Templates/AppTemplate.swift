enum AppTemplate {
    static func files(for ctx: ProjectContext) -> [ScaffoldFile] {
        [
            ScaffoldFile(
                path: "Sources/\(ctx.appTarget)/main.swift",
                content: main(ctx)
            )
        ]
    }

    private static func main(_ ctx: ProjectContext) -> String {
        """
        import DDDKit
        import Foundation
        import KurrentDB
        import \(ctx.aggregateTarget)

        // Runnable walkthrough: create -> rename -> project (read side) -> delete,
        // all against a real KurrentDB. Requires KurrentDB running locally — see README.md.

        struct MissingEnvironmentVariableError: Error, CustomStringConvertible {
            let name: String
            var description: String { "Missing required environment variable: \\(name)" }
        }

        @main
        struct \(ctx.appTarget) {
            static func main() async throws {
                guard let esdbURL = ProcessInfo.processInfo.environment["KURRENT_DB_URL"] else {
                    throw MissingEnvironmentVariableError(name: "KURRENT_DB_URL")
                }
                let settings: ClientSettings = try esdbURL.parse()
                let client = KurrentDBClient(settings: settings)

                let store = KurrentStorageCoordinator<\(ctx.aggregateName), CustomMetadata>(
                    client: client,
                    eventMapper: \(ctx.aggregateTarget)EventMapper()
                )
                let repository = \(ctx.aggregateName)Repository(store: store)

                let id = UUID().uuidString
                let operatorId = "demo-operator"

                print("=== \(ctx.projectName) Demo ===\\n")

                print("-- Create \(ctx.aggregateName)")
                let created = try await Create\(ctx.aggregateName)Service(repository: repository)
                    .execute(input: .init(id: id, name: "First \(ctx.aggregateName)", operatorId: operatorId))
                print("-> created id: \\(created.id ?? "-")\\n")

                print("-- Rename \(ctx.aggregateName)")
                let renamed = try await Rename\(ctx.aggregateName)Service(repository: repository)
                    .execute(input: .init(id: id, name: "Renamed \(ctx.aggregateName)", operatorId: operatorId))
                print("-> renamed id: \\(renamed.id ?? "-")\\n")

                print("-- Read side: project \(ctx.aggregateName)Summary")
                let projector = \(ctx.aggregateName)SummaryProjector(store: store)
                if let output = try await projector.execute(input: .init(id: id)) {
                    print("-> summary: \\(output.readModel)\\n")
                }

                print("-- Delete \(ctx.aggregateName)")
                let deleted = try await Delete\(ctx.aggregateName)Service(repository: repository)
                    .execute(input: .init(id: id, operatorId: operatorId))
                print("-> deleted id: \\(deleted.id ?? "-")\\n")

                print("=== Done ===")
            }
        }
        """
    }
}
