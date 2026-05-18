import Foundation

/// Non-generic storage holder for TaskLocal metadata, using a dictionary to
/// store per-type values. This works around the limitation that @TaskLocal
/// cannot be applied to generic static properties.
private enum _EventMetadataStorage {
    @TaskLocal static var all: [ObjectIdentifier: any EventMetadata] = [:]
}

/// Type-safe accessor for a specific metadata type M.
public struct _TaskLocalAccessor<M: EventMetadata> {
    /// Ambient scope setter: executes the operation with M set as the current metadata.
    /// Automatically restored when the scope exits.
    public func withValue<R>(_ value: M, operation: @escaping () async -> R) async -> R {
        let typeId = ObjectIdentifier(M.self)
        var storage = _EventMetadataStorage.all
        storage[typeId] = value

        return await _EventMetadataStorage.$all.withValue(storage) {
            let result = await operation()
            return result
        }
    }
}

/// Ambient TaskLocal carrier for event metadata, parameterised by the metadata
/// schema. Each concrete `M` has an independent storage slot.
///
/// Usecase sets the current metadata at entry:
/// ```swift
/// try await EventMetadataContext<AuditMetadata>.$current.withValue(audit) {
///     try await repository.save(aggregateRoot: order)
/// }
/// ```
///
/// `EventSourcingRepository.save` default impl reads
/// `EventMetadataContext<Store.Metadata>.current` — typed, no `as?` cast.
///
/// **Note on `Task.detached`:** TaskLocal inheritance follows Swift's standard
/// rules — structured `async let` / `TaskGroup` inherit; `Task.detached` does
/// not. If framework or application code uses `Task.detached` across a metadata
/// boundary, capture and re-apply explicitly.
public enum EventMetadataContext<M: EventMetadata> {
    private static var _typeId: ObjectIdentifier { ObjectIdentifier(M.self) }

    /// Current metadata value, or nil if none is set.
    public static var current: M? {
        _EventMetadataStorage.all[_typeId] as? M
    }

    /// Access to the TaskLocal-like storage for this metadata type.
    /// Note: Named `_current` instead of `$current` because Swift reserves the `$` prefix
    /// for synthesized property accessors (e.g., from @TaskLocal). Direct declaration of
    /// properties with `$` prefix is not allowed in the language.
    public static var _current: _TaskLocalAccessor<M> {
        _TaskLocalAccessor<M>()
    }
}
