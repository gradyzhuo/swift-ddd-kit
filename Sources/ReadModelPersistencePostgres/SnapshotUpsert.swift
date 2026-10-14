// Sources/ReadModelPersistencePostgres/SnapshotUpsert.swift
import PostgresNIO

/// The single upsert statement both Postgres snapshot stores issue.
enum SnapshotUpsert {
    static func query(
        table: String,
        id: String,
        typeName: String,
        json: String,
        revision: Int64,
        mode: SnapshotWriteMode
    ) -> PostgresQuery {
        switch mode {
        case .overwrite:
            return """
                INSERT INTO \(unescaped: table) (id, type, data, revision, updated_at)
                VALUES (\(id), \(typeName), \(json)::jsonb, \(revision), now())
                ON CONFLICT (id, type) DO UPDATE SET
                    data = EXCLUDED.data,
                    revision = EXCLUDED.revision,
                    updated_at = EXCLUDED.updated_at
                """
        case .monotonic:
            return """
                INSERT INTO \(unescaped: table) (id, type, data, revision, updated_at)
                VALUES (\(id), \(typeName), \(json)::jsonb, \(revision), now())
                ON CONFLICT (id, type) DO UPDATE SET
                    data = EXCLUDED.data,
                    revision = EXCLUDED.revision,
                    updated_at = EXCLUDED.updated_at
                WHERE \(unescaped: table).revision < EXCLUDED.revision
                RETURNING 1
                """
        }
    }
}
