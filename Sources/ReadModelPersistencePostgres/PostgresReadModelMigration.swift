import PostgresNIO

/// Utility for setting up the read model snapshot table in PostgreSQL.
public enum PostgresReadModelMigration {

    /// Creates the `read_model_snapshots` table if it does not already exist.
    ///
    /// This is idempotent — safe to call on every startup.
    ///
    /// - Parameters:
    ///   - client: An active `PostgresClient`.
    ///   - tableName: Table name to create (default: `"read_model_snapshots"`).
    public static func createTable(
        on client: PostgresClient,
        tableName: String = "read_model_snapshots"
    ) async throws {
        try await client.query("""
            CREATE TABLE IF NOT EXISTS \(unescaped: tableName) (
                id         TEXT        NOT NULL,
                type       TEXT        NOT NULL,
                data       JSONB       NOT NULL,
                revision   BIGINT      NOT NULL,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                PRIMARY KEY (id, type)
            )
            """)
    }
}
