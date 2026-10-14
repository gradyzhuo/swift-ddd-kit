import Testing
import Foundation
import PostgresNIO
import EventSourcing
import ReadModelPersistence
@testable import ReadModelPersistencePostgres

private struct Kept: ReadModel, Sendable { let id: String }
private struct Purged: ReadModel, Sendable { let id: String }

@Suite("PostgresReadModelSnapshots", .serialized)
struct PostgresReadModelSnapshotsTests {
    @Test("Purges only the listed types, only in the table of its write mode")
    func purgesListedTypesOnly() async throws {
        let client = PostgresClient(configuration: .testDefault)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            let base = "purge_\(UUID().uuidString.prefix(8).lowercased())"
            try await PostgresReadModelMigration.createTable(on: client, tableName: base, writeMode: .monotonic)
            let kept = PostgresJSONReadModelStore<Kept>(client: client, tableName: base)
            let purged = PostgresJSONReadModelStore<Purged>(client: client, tableName: base)
            try await kept.save(readModel: Kept(id: "1"), revision: 1)
            try await purged.save(readModel: Purged(id: "1"), revision: 1)

            let snapshots = PostgresReadModelSnapshots(client: client, tableName: base)
            try await snapshots.purgeSnapshots(ofTypes: [Purged.readModelTypeName])
            try await snapshots.purgeSnapshots(ofTypes: [Purged.readModelTypeName]) // idempotent

            #expect(try await kept.fetch(byId: "1")?.revision == 1)
            #expect(try await purged.fetch(byId: "1") == nil)
            try await client.query("DROP TABLE \(unescaped: base + "_monotonic")")
            group.cancelAll()
        }
    }
}
