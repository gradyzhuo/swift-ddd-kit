enum TestsTemplate {
    static func files(for ctx: ProjectContext) -> [ScaffoldFile] {
        [
            ScaffoldFile(
                path: "Tests/\(ctx.testsTarget)/\(ctx.aggregateName)Tests.swift",
                content: tests(ctx)
            )
        ]
    }

    private static func tests(_ ctx: ProjectContext) -> String {
        """
        import Testing
        @testable import \(ctx.aggregateTarget)

        // These tests exercise \(ctx.aggregateName) directly — no repository, no KurrentDB,
        // no `swift test` prerequisites. See \(ctx.appTarget)/main.swift for the
        // repository + KurrentDB-backed walkthrough.
        @Suite("\(ctx.aggregateName)")
        struct \(ctx.aggregateName)Tests {

            @Test("create sets id and name, and records a \(ctx.createdEvent) event")
            func createRecordsEvent() throws {
                let \(ctx.varName) = try \(ctx.aggregateName)(id: "id-1", name: "First")

                #expect(\(ctx.varName).id == "id-1")
                #expect(\(ctx.varName).name == "First")
                #expect(\(ctx.varName).events.count == 1)
                #expect(\(ctx.varName).events.first is \(ctx.createdEvent))
            }

            @Test("create rejects an empty name")
            func createRejectsEmptyName() {
                #expect(throws: \(ctx.aggregateName)Error.self) {
                    _ = try \(ctx.aggregateName)(id: "id-1", name: "   ")
                }
            }

            @Test("rename updates name and records a \(ctx.renamedEvent) event")
            func renameUpdatesName() throws {
                let \(ctx.varName) = try \(ctx.aggregateName)(id: "id-1", name: "First")
                try \(ctx.varName).clearAllDomainEvents()

                try \(ctx.varName).rename(to: "Second")

                #expect(\(ctx.varName).name == "Second")
                #expect(\(ctx.varName).events.count == 1)
                #expect(\(ctx.varName).events.first is \(ctx.renamedEvent))
            }

            @Test("rename rejects an empty name")
            func renameRejectsEmptyName() throws {
                let \(ctx.varName) = try \(ctx.aggregateName)(id: "id-1", name: "First")

                #expect(throws: \(ctx.aggregateName)Error.self) {
                    try \(ctx.varName).rename(to: "   ")
                }
            }

            @Test("markDelete marks the aggregate as deleted")
            func deleteMarksDeleted() throws {
                let \(ctx.varName) = try \(ctx.aggregateName)(id: "id-1", name: "First")

                try \(ctx.varName).markDelete()

                #expect(\(ctx.varName).deleted)
            }

            @Test("mutating a deleted aggregate throws")
            func mutatingAfterDeleteThrows() throws {
                let \(ctx.varName) = try \(ctx.aggregateName)(id: "id-1", name: "First")
                try \(ctx.varName).markDelete()

                #expect(throws: (any Error).self) {
                    try \(ctx.varName).rename(to: "Nope")
                }
            }
        }
        """
    }
}
