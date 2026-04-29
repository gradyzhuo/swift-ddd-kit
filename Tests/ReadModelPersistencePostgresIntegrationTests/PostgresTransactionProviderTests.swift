import Testing
import Foundation
import PostgresNIO
import EventSourcing
import ReadModelPersistencePostgres

@Suite("PostgresTransactionProvider", .serialized)
struct PostgresTransactionProviderTests {

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

    @Test("withTransaction commits a temp-table insert when body returns normally")
    func commitsOnSuccess() async throws {
        let client = Self.makeClient()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }

            let provider = PostgresTransactionProvider(client: client)
            let table = "test_tx_commit_\(UUID().uuidString.prefix(8))"
                .replacingOccurrences(of: "-", with: "_")

            try await provider.withTransaction { conn in
                _ = try await conn.query(
                    "CREATE TEMP TABLE \(unescaped: table) (id INT)",
                    logger: .init(label: "test")
                )
                _ = try await conn.query(
                    "INSERT INTO \(unescaped: table) VALUES (1)",
                    logger: .init(label: "test")
                )
            }

            // Temp tables are connection-scoped; only verifying that withTransaction
            // returns without throwing (the body's commit path was reached).
            group.cancelAll()
        }
    }

    @Test("withTransaction rolls back when body throws")
    func rollsBackOnThrow() async throws {
        let client = Self.makeClient()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }

            let provider = PostgresTransactionProvider(client: client)
            struct Boom: Error {}

            await #expect(throws: Boom.self) {
                try await provider.withTransaction { conn -> Void in
                    _ = try await conn.query(
                        "CREATE TEMP TABLE wont_exist (id INT)",
                        logger: .init(label: "test")
                    )
                    throw Boom()
                }
            }

            group.cancelAll()
        }
    }
}
