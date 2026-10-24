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
        try await checkStreamIsolation(make)
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

        // An empty append must leave committed history exactly as it was, whatever
        // the version: same events, same content, same tail, and still appendable.
        let seeded = events(2, id: id)
        _ = try await store.append(events: seeded, byId: id, version: nil, metadata: nil)
        func requireIntact(_ step: String) async throws {
            let fetched = try await store.fetchEvents(byId: id)
            try requireContent(fetched?.events, seeded, rule, step)
            try require(fetched?.latestRevision == 1, rule, "\(step): latestRevision \(String(describing: fetched?.latestRevision)), expected 1")
        }
        for version: UInt64? in [nil, 0, 1, 99] {
            let step = "empty append on an existing stream with version \(version.map { "\($0)" } ?? "nil")"
            let result = try await store.append(events: [], byId: id, version: version, metadata: nil)
            try require(result == nil, rule, "\(step) returned \(String(describing: result)), expected nil")
            try await requireIntact(step)
        }
        let next = events(1, id: id)
        let appended = try await store.append(events: next, byId: id, version: 1, metadata: nil)
        try require(appended == 2, rule, "append at the real tail after empty appends returned \(String(describing: appended)), expected 2")
        let afterNext = try await store.fetchEvents(byId: id)
        try requireContent(afterNext?.events, seeded + next, rule, "append after empty appends")

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

        let created = events(2, id: id)
        let first = try await store.append(events: created, byId: id, version: nil, metadata: nil)
        try require(first == 1, rule, "two events on a new stream returned \(String(describing: first)), expected 1")
        let fetched = try await store.fetchEvents(byId: id)
        try require(fetched?.latestRevision == 1, rule, "latestRevision \(String(describing: fetched?.latestRevision)), expected 1")
        try require(fetched?.events.count == 2, rule, "read \(String(describing: fetched?.events.count)) events, expected 2")
        let nextEvents = events(1, id: id)
        let next = try await store.append(events: nextEvents, byId: id, version: 1, metadata: nil)
        try require(next == 2, rule, "append at 1 returned \(String(describing: next)), expected 2")
        let fetchedAll = try await store.fetchEvents(byId: id)
        try requireContent(fetchedAll?.events, created + nextEvents, rule, "reading both appends")
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
        try requireContent(fetched?.events, batch + [later], rule, "reading the stream")
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

    /// A `version` far beyond the tail (up to `UInt64.max`) is just a mismatch and
    /// must throw `commitConflict`, not trap. Not part of `checkAll` yet: how a real
    /// KurrentDB server answers such revisions is unverified until the live contract
    /// run, so each backend's tests call it explicitly.
    public static func checkHugeVersionConflicts<S: EventStore>(
        _ make: Make<S>
    ) async throws where S.Metadata == ContractMetadata {
        let rule = "3.4 any mismatched version conflicts"
        let store = try await make()
        let id = newId()
        _ = try await store.append(events: events(1, id: id), byId: id, version: nil, metadata: nil)

        for version in [UInt64.max, UInt64.max - 1, UInt64(Int.max), UInt64(Int.max) + 1] {
            let conflict = try await expectDDDError(.commitConflict, rule) {
                try await store.append(events: events(1, id: id), byId: id, version: version, metadata: nil)
            }
            try require(
                conflict.commitConflict == DDDError.CommitConflict(id: id, expected: version, actual: 0),
                rule, "version \(version): \(String(describing: conflict.commitConflict))")
        }
        let fetched = try await store.fetchEvents(byId: id)
        try require(fetched?.events.count == 1, rule, "a failed append wrote events")
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

        func requireUnchanged(_ step: String) async throws {
            let fetched = try await store.fetchEvents(byId: id)
            try requireContent(fetched?.events, created + appended, rule, "\(step) changed the stream")
            try require(fetched?.latestRevision == 2, rule, "\(step): latestRevision \(String(describing: fetched?.latestRevision)), expected 2")
        }
        try await requireUnchanged("a resend")

        // The matched segment is no longer the tail: the answer is the last revision
        // of that segment, not the current tail.
        let resentCreateLater = try await store.append(events: created, byId: id, version: nil, metadata: nil)
        try require(resentCreateLater == 1, rule, "resent create after a later append returned \(String(describing: resentCreateLater)), expected 1 (its own last revision, not the tail)")
        try await requireUnchanged("resending the create batch after a later append")

        // The ids exist in the stream, but not right after the expected position.
        _ = try await expectDDDError(.commitConflict, rule) {
            try await store.append(events: appended, byId: id, version: nil, metadata: nil)
        }
        try await requireUnchanged("resending a batch at the wrong position")
        _ = try await expectDDDError(.commitConflict, rule) {
            try await store.append(events: created, byId: id, version: 0, metadata: nil)
        }
        try await requireUnchanged("resending a batch at a shifted position")

        _ = try await expectDDDError(.commitConflict, rule) {
            try await store.append(events: events(1, id: id), byId: id, version: 1, metadata: nil)
        }
        try await requireUnchanged("a conflicting append")
        let partial = [created[0], ContractEvent(aggregateRootId: id, value: 9)]
        _ = try await expectDDDError(.commitConflict, rule) {
            try await store.append(events: partial, byId: id, version: nil, metadata: nil)
        }
        try await requireUnchanged("a partially overlapping batch")
    }

    public static func checkConcurrentAppendsOneWins<S: EventStore>(
        _ make: Make<S>
    ) async throws where S.Metadata == ContractMetadata {
        let rule = "3.4 concurrent appends at the same version"
        let store = try await make()

        for round in 0..<concurrentRounds {
            let id = newId()
            let seed = events(1, id: id)
            _ = try await store.append(events: seed, byId: id, version: nil, metadata: nil)

            let firstBatch = [ContractEvent(aggregateRootId: id, value: 1)]
            let secondBatch = [ContractEvent(aggregateRootId: id, value: 2)]
            async let first = attemptAppend(store, firstBatch, id: id, version: 0)
            async let second = attemptAppend(store, secondBatch, id: id, version: 0)
            let results = await [(firstBatch, first), (secondBatch, second)]

            let winners = results.filter { if case .success = $0.1 { true } else { false } }
            try require(winners.count == 1, rule, "round \(round): \(winners.count) of 2 appends succeeded")
            for case let (_, .failure(error)) in results {
                try require((error as? DDDError)?.code == .commitConflict, rule, "round \(round): loser threw \(error)")
            }
            let fetched = try await store.fetchEvents(byId: id)
            try requireContent(fetched?.events, seed + winners[0].0, rule, "round \(round): stream is not the seed followed by exactly the winner's events")
            try require(fetched?.latestRevision == 1, rule, "round \(round): latestRevision \(String(describing: fetched?.latestRevision)), expected 1")

            // Two creates (`version: nil`) racing on a missing stream: one creates
            // it, the other conflicts against the winner's tail. Batch sizes differ
            // so the winner's revision tells which batch landed.
            let createId = newId()
            let twoEvents = events(2, id: createId)
            let oneEvent = events(1, id: createId)
            async let firstCreate = attemptAppend(store, twoEvents, id: createId, version: nil)
            async let secondCreate = attemptAppend(store, oneEvent, id: createId, version: nil)
            let creates = await [(twoEvents, firstCreate), (oneEvent, secondCreate)]

            let createWinners = creates.compactMap { batch, result -> ([ContractEvent], UInt64?)? in
                if case let .success(revision) = result { (batch, revision) } else { nil }
            }
            try require(createWinners.count == 1, rule, "round \(round): \(createWinners.count) of 2 concurrent creates succeeded")
            let (createdBatch, createdRevision) = createWinners[0]
            let winnerTail = UInt64(createdBatch.count - 1)
            try require(createdRevision == winnerTail, rule, "round \(round): winning create returned \(String(describing: createdRevision)), expected \(winnerTail)")
            for case let (_, .failure(error)) in creates {
                let conflict = (error as? DDDError)?.commitConflict
                try require(
                    conflict == DDDError.CommitConflict(id: createId, expected: nil, actual: winnerTail),
                    rule, "round \(round): losing create threw \(error), expected commitConflict(expected: nil, actual: \(winnerTail))")
            }
            let fetchedCreate = try await store.fetchEvents(byId: createId)
            try requireContent(fetchedCreate?.events, createdBatch, rule, "round \(round): created stream is not exactly the winning create's batch")
            try require(fetchedCreate?.latestRevision == winnerTail, rule, "round \(round): created stream latestRevision \(String(describing: fetchedCreate?.latestRevision)), expected \(winnerTail)")
        }
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
        try requireContent(afterFirst?.events, Array(written[1...]), rule, "after 0")
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
        let fetchedNeverAfter = try await store.fetchEvents(byId: neverWritten, afterRevision: 0)
        try require(fetchedNeverAfter == nil, rule, "purging an unknown id made it readable after a revision")
        _ = try await expectDDDError(.streamPurged, rule) {
            try await store.append(events: events(1, id: neverWritten), byId: neverWritten, version: nil, metadata: nil)
        }
        // §3.4/§3.5: a purged id rejects every non-empty append, whatever the version.
        _ = try await expectDDDError(.streamPurged, rule) {
            try await store.append(events: events(1, id: neverWritten), byId: neverWritten, version: 0, metadata: nil)
        }
        try await store.purge(byId: neverWritten)
        let fetchedNeverAgain = try await store.fetchEvents(byId: neverWritten)
        try require(fetchedNeverAgain == nil, rule, "a second purge of an unknown id made it readable")
    }

    // MARK: - Stream isolation

    /// Writes to, conflicts on and purges of one id never touch another id's
    /// committed history.
    public static func checkStreamIsolation<S: EventStore>(
        _ make: Make<S>
    ) async throws where S.Metadata == ContractMetadata {
        let rule = "3.2 streams are isolated"
        let store = try await make()
        let a = newId()
        let b = newId()
        let aEvents = events(2, id: a)
        var bEvents = events(1, id: b)

        func requireA(_ step: String) async throws {
            let fetched = try await store.fetchEvents(byId: a)
            try requireContent(fetched?.events, aEvents, rule, "stream A after \(step)")
            try require(fetched?.latestRevision == 1, rule, "stream A after \(step): latestRevision \(String(describing: fetched?.latestRevision)), expected 1")
            let after = try await store.fetchEvents(byId: a, afterRevision: 0)
            try requireContent(after?.events, [aEvents[1]], rule, "stream A after 0, after \(step)")
        }
        func requireB(_ step: String) async throws {
            let fetched = try await store.fetchEvents(byId: b)
            try requireContent(fetched?.events, bEvents, rule, "stream B after \(step)")
            try require(
                fetched?.latestRevision == UInt64(bEvents.count - 1), rule,
                "stream B after \(step): latestRevision \(String(describing: fetched?.latestRevision)), expected \(bEvents.count - 1)")
        }

        _ = try await store.append(events: aEvents, byId: a, version: nil, metadata: nil)
        _ = try await store.append(events: bEvents, byId: b, version: nil, metadata: nil)
        try await requireA("creating B")
        try await requireB("creating B")

        let more = events(2, id: b)
        _ = try await store.append(events: more, byId: b, version: 0, metadata: nil)
        bEvents += more
        try await requireA("appending to B")
        try await requireB("appending to B")

        _ = try await expectDDDError(.commitConflict, rule) {
            try await store.append(events: events(1, id: b), byId: b, version: 0, metadata: nil)
        }
        try await requireA("a conflicting append to B")
        try await requireB("a conflicting append to B")

        let c = newId()
        _ = try await store.append(events: events(1, id: c), byId: c, version: nil, metadata: nil)
        try await store.purge(byId: c)
        try await store.purge(byId: newId())
        try await requireA("creating and purging C")
        try await requireB("creating and purging C")

        try await store.purge(byId: b)
        try await requireA("purging B")
        let fetchedB = try await store.fetchEvents(byId: b)
        try require(fetchedB == nil, rule, "purged stream B is still readable")

        let aNext = events(1, id: a)
        let aTail = try await store.append(events: aNext, byId: a, version: 1, metadata: nil)
        try require(aTail == 2, rule, "append to A after purging B returned \(String(describing: aTail)), expected 2")
        let fetchedA = try await store.fetchEvents(byId: a)
        try requireContent(fetchedA?.events, aEvents + aNext, rule, "stream A after appending to it")
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

        // Interleaved: skipping must continue past an unmapped/undecodable event, and
        // revisions are the real stream revisions, not positions among mapped events.
        let interleaved = newId()
        let firstMapped = ContractEvent(aggregateRootId: interleaved, value: 1)
        let secondMapped = ContractEvent(aggregateRootId: interleaved, value: 3)
        let interleavedEvents: [any DomainEvent] = [
            ContractUnmappedEvent(aggregateRootId: interleaved),
            firstMapped,
            ContractUndecodableEvent(aggregateRootId: interleaved),
            secondMapped,
            ContractUnmappedEvent(aggregateRootId: interleaved),
        ]
        let interleavedTail = try await store.append(events: interleavedEvents, byId: interleaved, version: nil, metadata: nil)
        try require(interleavedTail == 4, rule, "interleaved append returned \(String(describing: interleavedTail)), expected 4")
        let fetchedInterleaved = try await store.fetchEvents(byId: interleaved)
        try require(
            fetchedInterleaved?.events.map { $0.id } == [firstMapped.id, secondMapped.id],
            rule, "interleaved: expected both mapped events in order, got \(String(describing: fetchedInterleaved?.events.map { $0.id }))")
        try require(fetchedInterleaved?.latestRevision == 3, rule, "interleaved latestRevision \(String(describing: fetchedInterleaved?.latestRevision)), expected 3")
        let afterInterleaved = try await store.fetchEvents(byId: interleaved, afterRevision: 1)
        try require(afterInterleaved?.events.map { $0.id } == [secondMapped.id], rule, "interleaved after 1 did not return exactly the mapped event at revision 3")
        try require(afterInterleaved?.latestRevision == 3, rule, "interleaved after 1 latestRevision \(String(describing: afterInterleaved?.latestRevision)), expected 3")

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

        // `metadata` applies to every event of the batch, not just the first.
        let batchId = newId()
        let batchTag = ContractMetadata(tag: "m-batch")
        _ = try await store.append(events: events(2, id: batchId), byId: batchId, version: nil, metadata: batchTag)
        let fetchedBatch = try await store.fetchEvents(byId: batchId)
        let readBatch = fetchedBatch?.events.compactMap { $0 as? ContractEvent } ?? []
        try require(readBatch.count == 2, rule, "batch: read \(readBatch.count) ContractEvents, expected 2")
        try require(
            readBatch.allSatisfy { $0.metadata == batchTag }, rule,
            "batch metadata \(readBatch.map { String(describing: $0.metadata) }), expected \(batchTag) on both events")
    }

    // MARK: - Helpers

    static func newId() -> String { UUID().uuidString }

    /// Fresh events with distinct non-zero values and distinct sub-second
    /// `occurred` timestamps, so a store that drops or rewrites any field shows.
    static func events(_ count: Int, id: String) -> [ContractEvent] {
        let base = Date().addingTimeInterval(-Double.random(in: 0..<86_400))
        return (0..<count).map {
            ContractEvent(
                aggregateRootId: id,
                value: Int.random(in: 1...1_000_000_000),
                occurred: base.addingTimeInterval(Double($0) * 1.25 + 0.000_5))
        }
    }

    /// How far a read-back `occurred` may drift from the written one. Stores may
    /// round dates through their encoding (a JSON number, a database timestamp
    /// column); anything within a millisecond counts as preserved.
    static let occurredTolerance: TimeInterval = 0.001

    /// `read` must be exactly `expected`, in order, with every field preserved:
    /// id, aggregate id, value and `occurred` (within `occurredTolerance`).
    /// Metadata has its own rule (`checkMetadataRoundTrip`).
    static func requireContent(
        _ read: [any DomainEvent]?, _ expected: [ContractEvent], _ rule: String, _ step: @autoclosure () -> String
    ) throws {
        guard let read else {
            throw ContractViolation(rule: rule, detail: "\(step()): the stream reads as missing, expected \(expected.count) events")
        }
        try require(
            read.map { $0.id } == expected.map { $0.id }, rule,
            "\(step()): read ids \(read.map { $0.id }), expected \(expected.map { $0.id })")
        for (index, (event, want)) in zip(read, expected).enumerated() {
            guard let got = event as? ContractEvent else {
                throw ContractViolation(rule: rule, detail: "\(step()): event \(index) came back as \(type(of: event)), expected ContractEvent")
            }
            try require(
                got.aggregateRootId == want.aggregateRootId, rule,
                "\(step()): event \(index) aggregateRootId \(got.aggregateRootId), expected \(want.aggregateRootId)")
            try require(got.value == want.value, rule, "\(step()): event \(index) value \(got.value), expected \(want.value)")
            try require(
                abs(got.occurred.timeIntervalSince(want.occurred)) <= occurredTolerance, rule,
                "\(step()): event \(index) occurred \(got.occurred.timeIntervalSinceReferenceDate), expected \(want.occurred.timeIntervalSinceReferenceDate)")
        }
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

    static let concurrentRounds = 20

    static func attemptAppend<S: EventStore>(
        _ store: S, _ batch: [ContractEvent], id: String, version: UInt64?
    ) async -> Result<UInt64?, any Error> where S.Metadata == ContractMetadata {
        do {
            return .success(try await store.append(events: batch, byId: id, version: version, metadata: nil))
        } catch {
            return .failure(error)
        }
    }
}
