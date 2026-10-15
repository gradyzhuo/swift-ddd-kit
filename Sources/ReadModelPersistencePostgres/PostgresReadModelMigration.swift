import PostgresNIO

/// Utility for setting up the read model snapshot table in PostgreSQL.
public enum PostgresReadModelMigration {

    /// Creates the snapshot table for `writeMode` if it does not already exist.
    ///
    /// Idempotent — safe to call on every startup. The physical table is
    /// `tableName` for `.overwrite` and `tableName + "_monotonic"` for `.monotonic`.
    public static func createTable(
        on client: PostgresClient,
        tableName: String = "read_model_snapshots",
        writeMode: SnapshotWriteMode = .monotonic
    ) async throws {
        let table = SnapshotTable.resolve(baseName: tableName, mode: writeMode)
        try await client.query("""
            CREATE TABLE IF NOT EXISTS \(unescaped: table) (
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
