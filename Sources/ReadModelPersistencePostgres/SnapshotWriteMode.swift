/// How a Postgres snapshot store resolves a write to a row that already exists.
///
/// The two modes live in **different tables** (see ``SnapshotTable``) so switching
/// modes never reuses rows written under the other mode's rules. Switching is a
/// rebuild: the new table starts empty, and only a subscription group reset to the
/// start re-creates every snapshot.
public enum SnapshotWriteMode: Sendable, Equatable {
    /// Unconditional upsert — the last commit wins. Stored in the base table.
    /// Use when a stream's revision can legitimately go backwards (stream hard-deleted
    /// and recreated under the same id).
    case overwrite
    /// Only a strictly newer revision replaces the stored row; an older or equal one
    /// is skipped. Safe with several consumers or out-of-order redelivery.
    /// Stored in `<base>_monotonic`.
    case monotonic
}

/// Physical table naming shared by every Postgres snapshot type.
enum SnapshotTable {
    static let defaultBaseName = "read_model_snapshots"

    static func resolve(baseName: String, mode: SnapshotWriteMode) -> String {
        let name = switch mode {
        case .overwrite: baseName
        case .monotonic: baseName + "_monotonic"
        }
        precondition(
            name.range(of: #"^[a-zA-Z_][a-zA-Z0-9_$]*$"#, options: .regularExpression) != nil,
            "Snapshot table name '\(name)' must be a valid SQL identifier (letters, digits, underscores, dollar signs; must start with a letter or underscore)"
        )
        precondition(
            name.utf8.count <= 63,
            "Snapshot table name '\(name)' exceeds Postgres' 63-byte identifier limit (Postgres would silently truncate it)"
        )
        return name
    }
}
