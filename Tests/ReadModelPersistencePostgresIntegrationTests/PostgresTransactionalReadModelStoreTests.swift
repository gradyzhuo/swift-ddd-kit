import Testing
import Foundation
import PostgresNIO
import DDDCore
import EventSourcing
import ReadModelPersistence
import ReadModelPersistencePostgres

@Suite("PostgresTransactionalReadModelStore", .serialized)
struct PostgresTransactionalReadModelStoreTests {

    private struct DemoModel: ReadModel, Codable, Sendable {
        typealias ID = String
        let id: String
        var value: String
    }

    private static func makeClient() -> PostgresClient {
        let cfg = PostgresClient.Configuration(
            host: ProcessInfo.processInfo.environment["PG_HOST"] ?? "localhost",
            port: Int(ProcessInfo.processInfo.environment["PG_PORT"] ?? "5432") ?? 5432,
            username: ProcessInfo.processInfo.environment["PG_USER"] ?? "postgres",
            password: ProcessInfo.processInfo.environment["PG_PASSWORD"] ?? "postgres",
            database: ProcessInfo.processInfo.environment["PG_DATABASE"] ?? "postgres",
            tls: .disable
        )
        return PostgresClient(configuration: cfg)
    }

    @Test("save in committed transaction is durable; fetch sees it")
    func saveAndFetchAfterCommit() async throws {
        let client = Self.makeClient()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }

            try await PostgresReadModelMigration.createTable(on: client)
            let store = PostgresTransactionalReadModelStore<DemoModel>()
            let provider = PostgresTransactionProvider(client: client)
            let id = "tx-test-\(UUID().uuidString.prefix(8))"

            try await provider.withTransaction { conn in
                let model = DemoModel(id: id, value: "committed")
                try await store.save(readModel: model, revision: 1, in: conn)
            }

            let stored: StoredReadModel<DemoModel>? = try await provider.withTransaction { conn in
                try await store.fetch(byId: id, in: conn)
            }

            #expect(stored?.readModel.value == "committed")
            #expect(stored?.revision == 1)

            group.cancelAll()
        }
    }

    @Test("save in rolled-back transaction is NOT durable; fetch sees nothing")
    func rollbackHidesWrites() async throws {
        let client = Self.makeClient()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }

            try await PostgresReadModelMigration.createTable(on: client)
            let store = PostgresTransactionalReadModelStore<DemoModel>()
            let provider = PostgresTransactionProvider(client: client)
            let id = "tx-rollback-\(UUID().uuidString.prefix(8))"

            struct Boom: Error {}
            await #expect(throws: Boom.self) {
                try await provider.withTransaction { conn -> Void in
                    let model = DemoModel(id: id, value: "should-not-stick")
                    try await store.save(readModel: model, revision: 1, in: conn)
                    throw Boom()
                }
            }

            let stored: StoredReadModel<DemoModel>? = try await provider.withTransaction { conn in
                try await store.fetch(byId: id, in: conn)
            }

            #expect(stored == nil)

            group.cancelAll()
        }
    }
}
