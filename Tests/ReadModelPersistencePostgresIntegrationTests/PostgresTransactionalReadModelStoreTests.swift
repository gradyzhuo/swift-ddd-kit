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
        PostgresClient(configuration: .testDefault)
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

    @Test("monotonic: a stale commit does not roll the snapshot back (two consumers, out of order)")
    func monotonicStaleCommitSkipped() async throws {
        let client = Self.makeClient()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            try await PostgresReadModelMigration.createTable(on: client)
            let store = PostgresTransactionalReadModelStore<DemoModel>()
            let provider = PostgresTransactionProvider(client: client)
            let id = "tx-mono-\(UUID().uuidString.prefix(8))"

            try await provider.withTransaction { conn in
                try await store.save(readModel: DemoModel(id: id, value: "rev6"), revision: 6, in: conn)
            }
            try await provider.withTransaction { conn in
                try await store.save(readModel: DemoModel(id: id, value: "rev5"), revision: 5, in: conn)
            }
            try await provider.withTransaction { conn in
                try await store.save(readModel: DemoModel(id: id, value: "rev6-again"), revision: 6, in: conn)
            }
            let stored: StoredReadModel<DemoModel>? = try await provider.withTransaction { conn in
                try await store.fetch(byId: id, in: conn)
            }
            #expect(stored?.readModel.value == "rev6")
            #expect(stored?.revision == 6)
            group.cancelAll()
        }
    }

    @Test("Custom table name and overwrite mode are honored")
    func customTableOverwrite() async throws {
        let client = Self.makeClient()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            let table = "tx_custom_\(UUID().uuidString.prefix(8).lowercased())"
            try await PostgresReadModelMigration.createTable(on: client, tableName: table, writeMode: .overwrite)
            let store = PostgresTransactionalReadModelStore<DemoModel>(tableName: table, writeMode: .overwrite)
            let provider = PostgresTransactionProvider(client: client)
            let id = "tx-custom-\(UUID().uuidString.prefix(8))"

            try await provider.withTransaction { conn in
                try await store.save(readModel: DemoModel(id: id, value: "rev6"), revision: 6, in: conn)
                try await store.save(readModel: DemoModel(id: id, value: "rev1"), revision: 1, in: conn)
            }
            let stored: StoredReadModel<DemoModel>? = try await provider.withTransaction { conn in
                try await store.fetch(byId: id, in: conn)
            }
            #expect(stored?.readModel.value == "rev1")
            try await client.query("DROP TABLE \(unescaped: table)")
            group.cancelAll()
        }
    }
}
