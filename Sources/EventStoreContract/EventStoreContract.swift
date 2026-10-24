import DDDCore
import EventSourcing
import Foundation

/// A rule of the `EventStore` contract that a store broke.
public struct ContractViolation: Error, CustomStringConvertible {
    public let rule: String
    public let detail: String

    public var description: String { "[\(rule)] \(detail)" }
}

/// The `EventStore` contract (spec A §3) as throwing checks. Each check builds a
/// fresh store with `make` and uses fresh UUID ids.
public enum EventStoreContract {
    public typealias Make<S> = () async throws -> S

    /// Runs every rule. Pass `serialized: true` for stores that persist bytes and
    /// decode through `ContractEventMapper`; that adds the mapper and metadata rules.
    public static func checkAll<S: EventStore>(
        serialized: Bool, _ make: Make<S>
    ) async throws where S.Metadata == ContractMetadata {
        try await checkEmptyAppendIsNoOp(make)
        try await checkRevisionsStartAtZero(make)
        try await checkStreamOrder(make)
        try await checkVersionPreconditions(make)
        try await checkIdempotentResend(make)
        try await checkConcurrentAppendsOneWins(make)
        try await checkAfterRevision(make)
        try await checkPurge(make)
        if serialized {
            try await checkUnmappedEventsAreSkipped(make)
            try await checkMetadataRoundTrip(make)
        }
    }

    // MARK: - §3.1

    public static func checkEmptyAppendIsNoOp<S: EventStore>(
        _ make: Make<S>
    ) async throws where S.Metadata == ContractMetadata {
        let rule = "3.1 empty append is a no-op"
        let store = try await make()
        let id = newId()

        let onNew = try await store.append(events: [], byId: id, version: nil, metadata: nil)
        try require(onNew == nil, rule, "empty append on a new stream returned \(String(describing: onNew))")
        let anyVersion = try await store.append(events: [], byId: id, version: 99, metadata: nil)
        try require(anyVersion == nil, rule, "empty append checked the version")
        let fetched = try await store.fetchEvents(byId: id)
        try require(fetched == nil, rule, "empty append created the stream")

        _ = try await store.append(events: events(1, id: id), byId: id, version: nil, metadata: nil)
        let onExisting = try await store.append(events: [], byId: id, version: nil, metadata: nil)
        try require(onExisting == nil, rule, "empty append on an existing stream with version nil did not return nil")

        try await store.purge(byId: id)
        let onPurged = try await store.append(events: [], byId: id, version: nil, metadata: nil)
        try require(onPurged == nil, rule, "empty append on a purged stream did not return nil")
    }

    public static func checkRevisionsStartAtZero<S: EventStore>(
        _ make: Make<S>
    ) async throws where S.Metadata == ContractMetadata {
        let rule = "3.1 revisions start at 0"
        let store = try await make()
        let id = newId()

        let first = try await store.append(events: events(2, id: id), byId: id, version: nil, metadata: nil)
        try require(first == 1, rule, "two events on a new stream returned \(String(describing: first)), expected 1")
        let fetched = try await store.fetchEvents(byId: id)
        try require(fetched?.latestRevision == 1, rule, "latestRevision \(String(describing: fetched?.latestRevision)), expected 1")
        try require(fetched?.events.count == 2, rule, "read \(String(describing: fetched?.events.count)) events, expected 2")
        let next = try await store.append(events: events(1, id: id), byId: id, version: 1, metadata: nil)
        try require(next == 2, rule, "append at 1 returned \(String(describing: next)), expected 2")
    }

    // MARK: - §3.2

    public static func checkStreamOrder<S: EventStore>(
        _ make: Make<S>
    ) async throws where S.Metadata == ContractMetadata {
        let rule = "3.2 events come back in stream order"
        let store = try await make()
        let id = newId()
        let now = Date()
        // `occurred` deliberately runs backwards: the store must not sort by it.
        let batch = [
            ContractEvent(aggregateRootId: id, value: 0, occurred: now),
            ContractEvent(aggregateRootId: id, value: 1, occurred: now.addingTimeInterval(-60)),
        ]
        let later = ContractEvent(aggregateRootId: id, value: 2, occurred: now.addingTimeInterval(-120))

        _ = try await store.append(events: batch, byId: id, version: nil, metadata: nil)
        _ = try await store.append(events: [later], byId: id, version: 1, metadata: nil)

        let fetched = try await store.fetchEvents(byId: id)
        let expected = batch.map { $0.id } + [later.id]
        try require(fetched?.events.map { $0.id } == expected, rule, "events were reordered")
    }

    // MARK: - §3.4

    public static func checkVersionPreconditions<S: EventStore>(
        _ make: Make<S>
    ) async throws where S.Metadata == ContractMetadata {
        let rule = "3.4 version preconditions"
        let store = try await make()
        let id = newId()
        _ = try await store.append(events: events(1, id: id), byId: id, version: nil, metadata: nil)

        let onExisting = try await expectDDDError(.commitConflict, rule) {
            try await store.append(events: events(1, id: id), byId: id, version: nil, metadata: nil)
        }
        try require(
            onExisting.commitConflict == DDDError.CommitConflict(id: id, expected: nil, actual: 0),
            rule, "nil on an existing stream: \(String(describing: onExisting.commitConflict))")

        let stale = try await expectDDDError(.commitConflict, rule) {
            try await store.append(events: events(1, id: id), byId: id, version: 5, metadata: nil)
        }
        try require(
            stale.commitConflict == DDDError.CommitConflict(id: id, expected: 5, actual: 0),
            rule, "wrong version: \(String(describing: stale.commitConflict))")

        let missing = newId()
        let onMissing = try await expectDDDError(.commitConflict, rule) {
            try await store.append(events: events(1, id: missing), byId: missing, version: 0, metadata: nil)
        }
        try require(
            onMissing.commitConflict == DDDError.CommitConflict(id: missing, expected: 0, actual: nil),
            rule, "version on a missing stream: \(String(describing: onMissing.commitConflict))")

        let fetched = try await store.fetchEvents(byId: id)
        try require(fetched?.events.count == 1, rule, "a failed append wrote events")
        let fetchedMissing = try await store.fetchEvents(byId: missing)
        try require(fetchedMissing == nil, rule, "a failed append created the stream")
    }

    public static func checkIdempotentResend<S: EventStore>(
        _ make: Make<S>
    ) async throws where S.Metadata == ContractMetadata {
        let rule = "3.4 idempotent resend"
        let store = try await make()
        let id = newId()

        let created = events(2, id: id)
        _ = try await store.append(events: created, byId: id, version: nil, metadata: nil)
        let resentCreate = try await store.append(events: created, byId: id, version: nil, metadata: nil)
        try require(resentCreate == 1, rule, "resent create returned \(String(describing: resentCreate)), expected 1")

        let appended = events(1, id: id)
        _ = try await store.append(events: appended, byId: id, version: 1, metadata: nil)
        let resentAppend = try await store.append(events: appended, byId: id, version: 1, metadata: nil)
        try require(resentAppend == 2, rule, "resent append returned \(String(describing: resentAppend)), expected 2")

        let fetched = try await store.fetchEvents(byId: id)
        try require(fetched?.events.count == 3, rule, "a resend wrote events again")

        _ = try await expectDDDError(.commitConflict, rule) {
            try await store.append(events: events(1, id: id), byId: id, version: 1, metadata: nil)
        }
        let partial = [created[0], ContractEvent(aggregateRootId: id, value: 9)]
        _ = try await expectDDDError(.commitConflict, rule) {
            try await store.append(events: partial, byId: id, version: nil, metadata: nil)
        }
    }

    public static func checkConcurrentAppendsOneWins<S: EventStore>(
        _ make: Make<S>
    ) async throws where S.Metadata == ContractMetadata {
        let rule = "3.4 concurrent appends at the same version"
        let store = try await make()
        let id = newId()
        _ = try await store.append(events: events(1, id: id), byId: id, version: nil, metadata: nil)

        async let first = attemptAppend(store, id: id, version: 0)
        async let second = attemptAppend(store, id: id, version: 0)
        let results = await [first, second]

        let successes = results.filter { if case .success = $0 { true } else { false } }
        try require(successes.count == 1, rule, "\(successes.count) of 2 appends succeeded")
        for case let .failure(error) in results {
            try require((error as? DDDError)?.code == .commitConflict, rule, "loser threw \(error)")
        }
        let fetched = try await store.fetchEvents(byId: id)
        try require(fetched?.events.count == 2, rule, "stream has \(String(describing: fetched?.events.count)) events, expected 2")
    }

    // MARK: - §3.3

    public static func checkAfterRevision<S: EventStore>(
        _ make: Make<S>
    ) async throws where S.Metadata == ContractMetadata {
        let rule = "3.3 fetchEvents(afterRevision:)"
        let store = try await make()
        let id = newId()
        let written = events(3, id: id)
        _ = try await store.append(events: written, byId: id, version: nil, metadata: nil)

        let afterFirst = try await store.fetchEvents(byId: id, afterRevision: 0)
        try require(afterFirst?.events.map { $0.id } == [written[1].id, written[2].id], rule, "after 0 returned the wrong events")
        try require(afterFirst?.latestRevision == 2, rule, "after 0 latestRevision \(String(describing: afterFirst?.latestRevision))")

        let atTail = try await store.fetchEvents(byId: id, afterRevision: 2)
        try require(atTail?.events.isEmpty == true, rule, "after the tail returned events")
        try require(atTail?.latestRevision == 2, rule, "after the tail latestRevision \(String(describing: atTail?.latestRevision)), expected 2")

        let missing = try await store.fetchEvents(byId: newId(), afterRevision: 0)
        try require(missing == nil, rule, "a missing stream did not return nil")
    }

    // MARK: - §3.5

    public static func checkPurge<S: EventStore>(
        _ make: Make<S>
    ) async throws where S.Metadata == ContractMetadata {
        let rule = "3.5 purge is permanent"
        let store = try await make()
        let id = newId()
        _ = try await store.append(events: events(1, id: id), byId: id, version: nil, metadata: nil)

        try await store.purge(byId: id)
        let fetched = try await store.fetchEvents(byId: id)
        try require(fetched == nil, rule, "a purged stream is still readable")
        let fetchedAfter = try await store.fetchEvents(byId: id, afterRevision: 0)
        try require(fetchedAfter == nil, rule, "a purged stream is still readable after a revision")
        _ = try await expectDDDError(.streamPurged, rule) {
            try await store.append(events: events(1, id: id), byId: id, version: nil, metadata: nil)
        }
        _ = try await expectDDDError(.streamPurged, rule) {
            try await store.append(events: events(1, id: id), byId: id, version: 0, metadata: nil)
        }
        try await store.purge(byId: id)

        let neverWritten = newId()
        try await store.purge(byId: neverWritten)
        let fetchedNever = try await store.fetchEvents(byId: neverWritten)
        try require(fetchedNever == nil, rule, "purging an unknown id made it readable")
        _ = try await expectDDDError(.streamPurged, rule) {
            try await store.append(events: events(1, id: neverWritten), byId: neverWritten, version: nil, metadata: nil)
        }
    }

    // MARK: - §3.2 / §3.4, serialized stores only

    public static func checkUnmappedEventsAreSkipped<S: EventStore>(
        _ make: Make<S>
    ) async throws where S.Metadata == ContractMetadata {
        let rule = "3.2 unmapped events are skipped"
        let store = try await make()
        let id = newId()
        let mapped = ContractEvent(aggregateRootId: id, value: 0)
        let written: [any DomainEvent] = [
            mapped,
            ContractUnmappedEvent(aggregateRootId: id),
            ContractUndecodableEvent(aggregateRootId: id),
        ]
        let tail = try await store.append(events: written, byId: id, version: nil, metadata: nil)
        try require(tail == 2, rule, "append returned \(String(describing: tail)), expected 2")

        let fetched = try await store.fetchEvents(byId: id)
        try require(fetched?.events.map { $0.id } == [mapped.id], rule, "unmapped events were not skipped")
        try require(fetched?.latestRevision == 0, rule, "latestRevision \(String(describing: fetched?.latestRevision)), expected the last mapped event (0)")

        let after = try await store.fetchEvents(byId: id, afterRevision: 0)
        try require(after?.events.isEmpty == true, rule, "after 0 returned unmapped events")
        try require(after?.latestRevision == 0, rule, "after 0 latestRevision \(String(describing: after?.latestRevision)), expected 0")

        let conflict = try await expectDDDError(.commitConflict, rule) {
            try await store.append(events: events(1, id: id), byId: id, version: 0, metadata: nil)
        }
        try require(conflict.commitConflict?.actual == 2, rule, "conflict actual \(String(describing: conflict.commitConflict?.actual)), expected the real tail 2")

        let onlyUnmapped = newId()
        _ = try await store.append(events: [ContractUnmappedEvent(aggregateRootId: onlyUnmapped)], byId: onlyUnmapped, version: nil, metadata: nil)
        let fetchedOnlyUnmapped = try await store.fetchEvents(byId: onlyUnmapped)
        try require(fetchedOnlyUnmapped == nil, rule, "a stream with no mapped events did not read as nil")
    }

    public static func checkMetadataRoundTrip<S: EventStore>(
        _ make: Make<S>
    ) async throws where S.Metadata == ContractMetadata {
        let rule = "3.4 metadata round trip"
        let store = try await make()
        let id = newId()
        let tagged = ContractMetadata(tag: "m-1")
        _ = try await store.append(events: events(1, id: id), byId: id, version: nil, metadata: tagged)
        _ = try await store.append(events: events(1, id: id), byId: id, version: 0, metadata: nil)

        let fetched = try await store.fetchEvents(byId: id)
        let read = fetched?.events.compactMap { $0 as? ContractEvent } ?? []
        try require(read.count == 2, rule, "read \(read.count) ContractEvents, expected 2")
        try require(read[0].metadata == tagged, rule, "metadata \(String(describing: read[0].metadata)), expected \(tagged)")
        try require(read[1].metadata == nil, rule, "nil metadata came back as \(String(describing: read[1].metadata))")
    }

    // MARK: - Helpers

    static func newId() -> String { UUID().uuidString }

    static func events(_ count: Int, id: String) -> [ContractEvent] {
        (0..<count).map { ContractEvent(aggregateRootId: id, value: $0) }
    }

    static func require(_ condition: Bool, _ rule: String, _ detail: @autoclosure () -> String) throws {
        guard condition else { throw ContractViolation(rule: rule, detail: detail()) }
    }

    static func expectDDDError<T>(
        _ code: DDDError.Code, _ rule: String, _ body: () async throws -> T
    ) async throws -> DDDError {
        do {
            let value = try await body()
            throw ContractViolation(rule: rule, detail: "expected DDDError \(code), but it succeeded with \(value)")
        } catch let error as DDDError {
            guard error.code == code else {
                throw ContractViolation(rule: rule, detail: "expected DDDError \(code), got \(error.code): \(error.message)")
            }
            return error
        } catch let violation as ContractViolation {
            throw violation
        } catch {
            throw ContractViolation(rule: rule, detail: "expected DDDError \(code), got \(error)")
        }
    }

    static func attemptAppend<S: EventStore>(
        _ store: S, id: String, version: UInt64
    ) async -> Result<UInt64?, any Error> where S.Metadata == ContractMetadata {
        do {
            return .success(try await store.append(events: events(1, id: id), byId: id, version: version, metadata: nil))
        } catch {
            return .failure(error)
        }
    }
}
