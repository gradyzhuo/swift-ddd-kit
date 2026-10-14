import Testing
import Foundation
import PostgresNIO
@testable import ReadModelPersistencePostgres

@Suite("SnapshotWriteMode table resolution")
struct SnapshotWriteModeTests {
    @Test("overwrite keeps the base name; monotonic appends _monotonic")
    func resolution() {
        #expect(SnapshotTable.resolve(baseName: "read_model_snapshots", mode: .overwrite) == "read_model_snapshots")
        #expect(SnapshotTable.resolve(baseName: "read_model_snapshots", mode: .monotonic) == "read_model_snapshots_monotonic")
    }

    #if compiler(>=6.2) // `#expect(processExitsWith:)` requires Swift 6.2+
    @Test("A base name that only exceeds 63 bytes once suffixed is rejected")
    func suffixedLengthRejected() async {
        await #expect(processExitsWith: .failure) {
            // Exit-test closures cannot capture context, so build the name inside.
            let base = String(repeating: "a", count: 60) // 60 + "_monotonic" = 70
            _ = SnapshotTable.resolve(baseName: base, mode: .monotonic)
        }
    }

    @Test("An overwrite base that folds to a monotonic table name is rejected, whatever its case")
    func overwriteAliasingMonotonicRejectedCaseInsensitively() async {
        await #expect(processExitsWith: .failure) {
            // Postgres folds unquoted identifiers to lowercase, so this is read_model_snapshots_monotonic.
            _ = SnapshotTable.resolve(baseName: "READ_MODEL_SNAPSHOTS_MONOTONIC", mode: .overwrite)
        }
    }
    #endif

    @Test("createTable builds the table for the chosen mode")
    func createTablePerMode() async throws {
        let client = PostgresClient(configuration: .testDefault)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            let base = "wm_\(UUID().uuidString.prefix(8).lowercased())"
            try await PostgresReadModelMigration.createTable(on: client, tableName: base, writeMode: .monotonic)
            let rows = try await client.query("SELECT to_regclass(\(base + "_monotonic"))::text, to_regclass(\(base))::text")
            for try await (mono, plain) in rows.decode((String?, String?).self) {
                #expect(mono == base + "_monotonic")
                #expect(plain == nil)
            }
            try await client.query("DROP TABLE \(unescaped: base + "_monotonic")")
            group.cancelAll()
        }
    }
}

extension PostgresClient.Configuration {
    /// Shared by this test target; reads PG_* env vars (see plan "Test infrastructure").
    static var testDefault: Self {
        let env = ProcessInfo.processInfo.environment
        return .init(
            host: env["PG_HOST"] ?? "localhost",
            port: Int(env["PG_PORT"] ?? "5432") ?? 5432,
            username: env["PG_USER"] ?? "postgres",
            password: env["PG_PASSWORD"] ?? "postgres",
            database: env["PG_DATABASE"] ?? "postgres",
            tls: .disable
        )
    }
}
