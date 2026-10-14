/// How a Postgres snapshot store resolves a write to a row that already exists.
///
/// The two modes live in **different tables** (base table and `<base>_monotonic`) so switching
/// modes never reuses rows written under the other mode's rules. Switching is a
/// rebuild: the new table starts empty, and only a subscription group reset to the
/// start re-creates every snapshot.
public enum SnapshotWriteMode: Sendable, Equatable {
    /// Unconditional upsert — the last commit wins. Stored in the base table.
    /// This is the pre-existing behaviour: appropriate for a single consumer with
    /// in-order delivery, or for keeping an existing `read_model_snapshots` table.
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
        if mode == .overwrite {
            precondition(
                // Tables are referenced unquoted, so Postgres folds the name to lowercase:
                // compare the way Postgres will see it.
                !baseName.lowercased().hasSuffix("_monotonic"),
                "Base table name '\(baseName)' must not end in '_monotonic': an overwrite table would alias the monotonic table of base '\(baseName.dropLast("_monotonic".count))'"
            )
        }
        precondition(
            // `\A`/`\z`, not `^`/`$`: ICU's `$` also matches before a trailing newline, and the
            // name is spliced into SQL unquoted, where that newline is just whitespace.
            name.range(of: #"\A[a-zA-Z_][a-zA-Z0-9_$]*\z"#, options: .regularExpression) != nil,
            "Snapshot table name '\(name)' must be a valid SQL identifier (letters, digits, underscores, dollar signs; must start with a letter or underscore)"
        )
        precondition(
            name.utf8.count <= 63,
            "Snapshot table name '\(name)' exceeds Postgres' 63-byte identifier limit (Postgres would silently truncate it)"
        )
        return name
    }
}
