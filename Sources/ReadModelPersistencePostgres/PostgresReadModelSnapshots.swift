import PostgresNIO
import ReadModelPersistence

/// Table-level operations on a Postgres snapshot table — currently purging, used by
/// `KurrentProjection.rebuild`.
///
/// Resolves the same physical table as the stores for a given
/// `(tableName, writeMode)` pair, so pass the values your stores use.
public struct PostgresReadModelSnapshots: ReadModelSnapshotPurging {
    private let client: PostgresClient
    private let tableName: String

    public init(
        client: PostgresClient,
        tableName: String = "read_model_snapshots",
        writeMode: SnapshotWriteMode = .monotonic
    ) {
        self.client = client
        self.tableName = SnapshotTable.resolve(baseName: tableName, mode: writeMode)
    }

    public func purgeSnapshots(ofTypes typeNames: [String]) async throws {
        guard !typeNames.isEmpty else { return }
        try await client.query(
            "DELETE FROM \(unescaped: tableName) WHERE type = ANY(\(typeNames))"
        )
    }
}
