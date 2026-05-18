// Sources/EventSourcing/EventMetadataContext.swift

/// Non-generic storage holder for ambient event metadata.
///
/// The framework needs a per-type "current" metadata slot, but Swift does not
/// allow `@TaskLocal` on static properties of generic types
/// ("static stored properties not supported in generic types"). The workaround:
/// a single non-generic TaskLocal dict keyed by `ObjectIdentifier(M.self)`,
/// with a typed read/write API surfaced on `EventMetadataContext<M>`.
private enum _EventMetadataStorage {
    @TaskLocal static var all: [ObjectIdentifier: any EventMetadata] = [:]
}

/// Ambient TaskLocal carrier for event metadata, parameterised by the metadata
/// schema. Each concrete `M` has an independent storage slot (keyed internally
/// by the metadata type).
///
/// Usecase sets the current metadata at entry:
/// ```swift
/// try await EventMetadataContext<AuditMetadata>.withValue(audit) {
///     try await repository.save(aggregateRoot: order)
/// }
/// ```
///
/// `EventSourcingRepository.save` default impl reads
/// `EventMetadataContext<Store.Metadata>.current` — typed, no `as?` cast at
/// the call site.
///
/// **Note on `Task.detached`:** TaskLocal inheritance follows Swift's standard
/// rules — structured `async let` / `TaskGroup` inherit; `Task.detached` does
/// not. If framework or application code uses `Task.detached` across a metadata
/// boundary, capture and re-apply explicitly.
public enum EventMetadataContext<M: EventMetadata> {
    /// Current metadata value, or nil if none is set in this task.
    public static var current: M? {
        _EventMetadataStorage.all[ObjectIdentifier(M.self)] as? M
    }

    /// Run `operation` with `value` as the current metadata for `M`.
    /// The previous value is restored when the operation returns.
    @discardableResult
    public static func withValue<R>(
        _ value: M,
        operation: @Sendable () async throws -> R
    ) async rethrows -> R {
        var updated = _EventMetadataStorage.all
        updated[ObjectIdentifier(M.self)] = value
        return try await _EventMetadataStorage.$all.withValue(updated) {
            try await operation()
        }
    }
}
