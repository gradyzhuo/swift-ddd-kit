# withUnitOfWork Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `withUnitOfWork { work in … }` collects every `repository.save` inside the block and writes them to KurrentDB in one atomic append when the block returns; existing usecases, repositories and composition roots do not change.

**Architecture:** A TaskLocal scope (`UnitOfWork`, EventSourcing) holds exactly one `UnitOfWorkBackend` and closes when the body returns. `KurrentStorageCoordinator` detects the scope and hands appends to a per-scope `KurrentUnitOfWorkBackend` (KurrentSupport) that returns predicted revisions, merges staged events into reads, and commits through the `EventStoreClient` seam: one stream via the existing v1 `append`, two or more via the new `appendAtomically` (KurrentDB v2 `AppendRecords`). Commit and `onCommitted` hooks run after the TaskLocal is unbound. The repository default implementations gate non-participating stores and poison the scope on store errors.

**Tech Stack:** Swift 6.1 tools-version (`Package.swift`; every supported 6.x toolchain stays supported), Swift Testing, `Synchronization.Mutex`, swift-kurrentdb **≥ 2.6.1** (Task 1 raises the floor once it is tagged; 2.6.0 cannot carry metadata through `AppendRecords`), KurrentDB 26.1.3 (CI image) for live tests, `InMemoryEventStoreClient` for offline tests.

**Spec:** `docs/superpowers/specs/2026-11-01-unit-of-work-design.md` (rev 8). Section numbers below (§) refer to it. Rev 7 incorporated three independent plan reviews (spec §11 items 16–20); rev 8 folded in the facts swift-kurrentdb 2.6.1 established on a live server (spec §9, §11 items 21–22).

## Global Constraints

- Target version 1.5.0. Public signatures of `Usecase`, `EventStore`, `EventSourcingRepository`, `KurrentStorageCoordinator` do not change (§8). **Source-breaking, by design, documented as SB in the migration page:** `EventStoreClient` gains `var identity: ObjectIdentifier { get }` with **no default** (never add a type-level default; two clusters must never be mistaken for one, §6.5) and `func appendAtomically(_:)` with a deprecated default that throws `atomicAppendUnsupported`; `EventStoreClientError` gains `consistencyViolations` and `atomicAppendUnsupported`.
- `EventStoreClientError` stays `Equatable`; `StreamConflict` hand-writes `==` because `StreamRevision` is not `Equatable` (Task 6).
- Behaviour outside a scope is unchanged, byte for byte: every existing test keeps passing without edits except the two `EventStoreClient` test doubles, which gain `identity`.
- Locks: `Mutex`/actor only, never `NSLock`. No `@unchecked Sendable` in `Sources/`. Test fixtures may keep the repo's existing style; tests that use `async let`/`TaskGroup` construct the aggregate inside the child task instead of passing a non-`Sendable` aggregate across the boundary.
- Never run bare `swift test`; always `--filter`. Offline suites: `EventSourcingTests`, `DDDKitUnitTests`, `KurrentSupportUnitTests`, `KurrentSupportInMemoryTests`, `LocalEventStoreTests`. `KurrentSupportUnitTests` is missing from CI's offline filter today; Task 6 adds it.
- A filter that names a suite is quoted and puts a dot between target and suite: `swift test --filter 'EventSourcingTests\.UnitOfWorkTests'`. Swift Testing names a test `Target.Suite/test()`, so `Target/Suite` matches nothing: `swift test` prints `warning: No matching test cases were run` and exits 0. A step that expects tests to run (every GREEN step, and a RED step that expects a runtime failure) checks the output for `Test run with N tests` (one line per test target) with N > 0; for a single suite, N equals `swift test list | grep -c 'Target\.Suite/'`. A run without that line has tested nothing, whatever its exit code. Only a RED step that expects a compile error is exempt.
- Live suite `KurrentLiveContractTests` needs a local single-node insecure KurrentDB 26.1.3 **and** the pool URL, otherwise `withPooledIntegrationTestClient` dials a TLS three-node cluster on 2111–2113:

```bash
docker run -d --name kurrentdb -p 2113:2113 -e KURRENTDB_CLUSTER_SIZE=1 -e KURRENTDB_INSECURE=true kurrentplatform/kurrentdb:26.1.3
export KURRENTDB_POOL_URLS='["esdb://admin:changeit@localhost:2113?tls=false"]'
```

- Error codes: conflicts are `DDDError.commitConflict` (501), purged `streamPurged` (502), misuse `operationNotAllow` (202). No new codes. A commit whose returned revisions differ from the prediction is **not** an error (log only, §6.4).
- Commit messages follow the repo's conventional style (`feat(scope): …`, `test(scope): …`, `docs(scope): …`) and end with the attribution lines the session reminder gives. Never commit on `main`. The plan is executed in its own session on a clean checkout of `main`; Task 1 Step 1 creates `feat/unit-of-work`.
- Replies to the user in Traditional Chinese; code, identifiers and commit messages in English.

## Review Focus

1. **A `Task { repository.save(...) }` launched inside the block that runs after the block returned** — it inherits the TaskLocal; it must throw `operationNotAllow` ("already ended"), never stage into a committed backend or write directly. Tests in Task 4 (`closedScopeRejectsBackendFailAndHooks`) and Task 8 (`escapedTaskAfterScopeEndThrowsAndWritesNothing`).
2. **`repository.save` inside an `onCommitted` hook** — the hook runs with `UnitOfWork.current == nil`, so the save writes straight to the server and is not atomic with the block; it must not be lost. Tests in Task 4 (`hooksRunOutsideScope`) and Task 8 (`saveInsideHookWritesDirectly`).
3. **Two aggregate types that produce the same stream name** — the second `save` must fail with `commitConflict`, never silently append to the other aggregate's batch. Test in Task 8 (`sameStreamFromTwoCoordinatorsConflicts`).
4. **Structured child tasks inside the block** (`async let`) stage concurrently and must share one backend created exactly once (`make()` runs inside the lock). Test in Task 8 (`concurrentChildTasksStageIntoOneBackend`).
5. **Cancellation during the body** — a `CancellationError` thrown out of the body must discard staged events and run no hook; nothing is written. Test in Task 4 (`cancelledBodyCommitsNothing`, race-free: the body awaits a signal the test cancels first).

---

### Task 1: Raise the swift-kurrentdb floor to 2.6.1

**Precondition (met 2026-11-03):** swift-kurrentdb 2.6.1 is tagged (`2.6.1` = commit 11fb8b42, marked Latest; PR #197 is the metadata fix this plan needs, PR #198 fixes `AppendSession`, which DDDKit does not use). Confirm with `git ls-remote --tags https://github.com/gradyzhuo/swift-kurrentdb 2.6.1` before resolving.

**Files:**
- Modify: `Package.swift:81` (`from: "2.6.0"` → `from: "2.6.1"`)
- Modify: `CLAUDE.md` (the sentence "swift-kurrentdb floor is 2.6.0" in the `EventStore` contract entry → 2.6.1)

- [ ] **Step 1: Branch**

```bash
git checkout -b feat/unit-of-work main
```

- [ ] **Step 2: Bump the floor and resolve**

Edit `Package.swift` and `CLAUDE.md`. Run: `swift package resolve && swift build --build-tests`
Expected: resolves the new version; builds clean.

- [ ] **Step 3: Confirm the existing offline suites still pass**

Run: `swift test --filter '(EventSourcingTests|DDDKitUnitTests|KurrentSupportInMemoryTests|EventStoreContractTests|LocalEventStoreTests)'`
Expected: PASS.

- [ ] **Step 4: Commit** (the spec and this plan are untracked; they land here)

```bash
git add Package.swift CLAUDE.md docs/superpowers/specs/2026-11-01-unit-of-work-design.md docs/superpowers/plans/2026-11-02-unit-of-work.md
git commit -m "build: require swift-kurrentdb 2.6.1 so AppendRecords carries customMetadata"
```

---

### Task 2: (dropped) Live spike against KurrentDB 26.1

The four questions this spike was to answer were settled by the swift-kurrentdb session on KurrentDB 26.1 and 26.2 and are pinned by live tests shipped with swift-kurrentdb 2.6.1 (PRs #197, #198); the answers are in spec §9 and already folded into Tasks 6, 7 and 9 below. Nothing to do here; the number stays so cross-references hold. `SpikeMetadata` is defined in Task 9.

---

### Task 3: `DDDError.commitConflict(conflicts:)`

**Files:**
- Modify: `Sources/DDDCore/Adapter/DDDError.swift` (after `commitConflict(id:expected:actual:)`)
- Test: `Tests/DDDKitUnitTests/DDDErrorStoreCodesTests.swift`

**Interfaces:**
- Produces: `public static func commitConflict(conflicts: [CommitConflict]) -> DDDError` (precondition: non-empty) and `public var commitConflicts: [CommitConflict]`. The single-conflict factory stays; its `commitConflicts` returns `[commitConflict!]`; other codes return `[]`. `commitConflict` (singular accessor) on the multi version returns the first element.

- [ ] **Step 1: Write the failing tests**

```swift
@Test("commitConflict(conflicts:) exposes all conflicts and the first as commitConflict")
func multiConflict() {
    let a = DDDError.CommitConflict(id: "q-1", expected: nil, actual: 0)
    let b = DDDError.CommitConflict(id: "b-1", expected: 3, actual: 4)
    let error = DDDError.commitConflict(conflicts: [a, b])
    #expect(error.code == .commitConflict)
    #expect(error.commitConflicts == [a, b])
    #expect(error.commitConflict == a)
}
@Test("single commitConflict reports itself in commitConflicts; other codes report none")
func singleAndOthers() {
    #expect(DDDError.commitConflict(id: "o-1", expected: nil, actual: 3).commitConflicts.count == 1)
    #expect(DDDError.streamPurged(id: "o-1").commitConflicts.isEmpty)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter 'DDDKitUnitTests\.DDDErrorStoreCodesTests'`
Expected: FAIL to compile ("no member commitConflicts").

- [ ] **Step 3: Implement** — store the array under `userInfos["commitConflicts"]` and the first under `"commitConflict"`; message lists every `id` as `"[commitConflict] Append to q-1, b-1 found other revisions."` (the `[\(errorCode)]` prefix every DDDError factory uses interpolates the case name); `commitConflicts` reads the array key, falling back to `[commitConflict]` for the single factory.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter 'DDDKitUnitTests\.DDDErrorStoreCodesTests'`
Expected: PASS, and the output shows `Test run with N tests … passed` with N equal to `swift test list | grep -c 'DDDKitUnitTests\.DDDErrorStoreCodesTests/'` (N > 0).

- [ ] **Step 5: Commit**

```bash
git add Sources/DDDCore/Adapter/DDDError.swift Tests/DDDKitUnitTests/DDDErrorStoreCodesTests.swift
git commit -m "feat(core): commitConflict can carry every conflicting stream"
```

---

### Task 4: `UnitOfWork` scope in EventSourcing

**Files:**
- Create: `Sources/EventSourcing/UnitOfWork/UnitOfWork.swift`
- Test: `Tests/EventSourcingTests/UnitOfWorkTests.swift`

**Interfaces:**
- Produces (all `public`, module EventSourcing):

```swift
public func withUnitOfWork<R>(_ body: (UnitOfWork) async throws -> R) async throws -> R

public final class UnitOfWork: Sendable {
    public let id: UUID
    public static var current: UnitOfWork? { get }              // TaskLocal-backed; stays non-nil in an escaped task even after the scope closed
    public var isFailed: Bool { get }
    public func fail(_ error: any Error) throws                // keeps the first cause; throws operationNotAllow once closed
    public func onCommitted(_ action: @escaping @Sendable () async throws -> Void) throws   // throws operationNotAllow once closed
    public func backend<B: UnitOfWorkBackend>(_ type: B.Type, identity: ObjectIdentifier, make: () -> B) throws -> B
}
public protocol UnitOfWorkBackend: AnyObject, Sendable { func commit() async throws }
public protocol UnitOfWorkParticipant {}
```

- Package-visible for Task 5: `package var failure: (any Error)? { get }` and `package static func failingCurrentOnError<R>(_ operation: () async throws -> R) async rethrows -> R` (calls `try? current?.fail(error)` then rethrows the original error; a plain pass-through outside a scope).
- State lives in one `Mutex<State>` (`import Synchronization`): `backend: (any UnitOfWorkBackend)?`, `backendIdentity: ObjectIdentifier?`, `failure: (any Error)?`, `hooks: [@Sendable () async throws -> Void]`, `closed: Bool`. TaskLocal storage mirrors `EventMetadataContext`: `private enum _UnitOfWorkStorage { @TaskLocal static var current: UnitOfWork? }`.
- `withUnitOfWork` (§6.2), in this order: if `current != nil` throw `DDDError.operationNotAllow(operation: "withUnitOfWork", reason: "already inside unit of work \(current.id)")`; create the scope; `let result = try await $current.withValue(scope) { try await body(scope) }` — **only the body is inside `withValue`**; whether it returned or threw, set `closed = true` (use `defer` inside the `withValue` closure); body threw → rethrow (no commit, no hooks); `isFailed` → throw `operationNotAllow(operation: "commit", reason: "unit of work failed", userInfos: ["cause": failure])`; else `try await backend?.commit()` (errors propagate, hooks skipped), then run the hooks in registration order, awaiting each, with `UnitOfWork.current == nil`; return `result`. A hook error propagates after the commit already happened.
- Closed scope: `backend(_:identity:make:)`, `fail(_:)`, `onCommitted(_:)` throw `operationNotAllow(operation: "backend" | "fail" | "onCommitted", reason: "unit of work \(id) already ended")`.
- `backend(_:identity:make:)`: one `withLock` does the whole get-or-create: closed → throw; stored and `type(of: stored) == B.self && identity == storedIdentity` → return it; stored but different type or identity → throw `operationNotAllow(operation: "backend", reason: "a unit of work commits through exactly one backend")`; nothing stored → `make()` inside the lock, store, return.

- [ ] **Step 1: Write the failing tests** (a test backend `final class RecordingBackend: UnitOfWorkBackend` with `Mutex<Int>` commit counter, an optional error to throw, and a flag the hooks can read to prove commit ran first):

```swift
@Test func currentIsNilOutsideAndSetInside()
@Test func nestedCallThrowsAndOuterStillCommits()        // inner: operationNotAllow; outer backend commit count == 1
@Test func bodyThrowDoesNotCommit()                       // commit count == 0, error rethrown
@Test func failThenNormalReturnThrowsWithCause()          // work.fail(MyError.x); return → operationNotAllow, userInfos["cause"] is MyError.x, commit count 0
@Test func secondFailKeepsFirstCause()
@Test func isFailedFlipsOnFail()                          // false before, true after; framework path via failingCurrentOnError also flips it
@Test func backendRegisteredOnceAndSharedByIdentity()     // same type+identity → same instance; different identity → operationNotAllow
@Test func backendOfAnotherTypeIsRejected()               // second type with the same identity → operationNotAllow
@Test func concurrentFirstRegistrationMakesOneBackend()   // async let two backend(...) calls with a make() that counts; make count == 1
@Test func hooksRunInOrderAfterCommitBeforeReturn()       // order [1,2]; each hook observed backend.committed == true
@Test func hooksRunOutsideScope()                         // inside a hook UnitOfWork.current == nil
@Test func hooksRunWhenNoBackend()
@Test func hooksSkippedOnBodyThrowFailOrCommitError()     // three cases, arguments:
@Test func hookErrorStopsLaterHooksAndPropagates()        // backend commit count == 1, second hook never ran
@Test func hookAfterFailNeverRuns()                       // work.fail then onCommitted → not run
@Test func closedScopeRejectsBackendFailAndHooks()        // capture `work` and a Task { } started inside the body that awaits a signal; after withUnitOfWork returned, release the signal: inside that task UnitOfWork.current === work, and work.backend / work.fail / work.onCommitted each throw operationNotAllow with reason containing "already ended"
@Test func cancelledBodyCommitsNothing()                  // body awaits a CheckedContinuation the test holds; test cancels the Task first, then resumes → CancellationError out of withUnitOfWork, commit count 0, no hook
@Test func idsDifferBetweenScopes()
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter 'EventSourcingTests\.UnitOfWorkTests'`
Expected: FAIL to compile ("cannot find 'withUnitOfWork'").

- [ ] **Step 3: Implement `Sources/EventSourcing/UnitOfWork/UnitOfWork.swift`** per the Interfaces block. `body` is not `@Sendable` (same shape as `EventMetadataContext.withValue`).

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter 'EventSourcingTests\.UnitOfWorkTests'`
Expected: PASS, and the output shows `Test run with N tests … passed` with N equal to `swift test list | grep -c 'EventSourcingTests\.UnitOfWorkTests/'` (N > 0).

- [ ] **Step 5: Commit**

```bash
git add Sources/EventSourcing/UnitOfWork/UnitOfWork.swift Tests/EventSourcingTests/UnitOfWorkTests.swift
git commit -m "feat(event-sourcing): withUnitOfWork scope with one backend, fail, onCommitted and close-on-return"
```

---

### Task 5: Repository gate and auto-fail

**Files:**
- Modify: `Sources/EventSourcing/EventSourcingRepository.swift:14-82` (`find(byId:hiddingDeleted:)`, `save`, `delete`, `purge`)
- Test: `Tests/EventSourcingTests/EventSourcingRepositoryUnitOfWorkTests.swift`
- Test: `Tests/LocalEventStoreTests/PersistentEventStoreUnitOfWorkTests.swift`

**Interfaces:**
- Consumes: `UnitOfWork.current`, `UnitOfWork.failingCurrentOnError`, `UnitOfWorkParticipant` (Task 4).
- Produces: inside a scope, `save` and `purge` throw `DDDError.operationNotAllow(operation: "save" | "purge", reason: "\(Store.self) cannot take part in a unit of work")` when `!(store is any UnitOfWorkParticipant)`. Auto-fail wraps **only the store calls and the gate**: in `find` the `store.fetchEvents` call; in `save` the gate and `store.append`; in `purge` the gate and `store.purge`; `delete` is `find` + `markDelete` + `save` and gets nothing extra — its `aggregateNotFound` and `markDelete` errors do not fail the scope (§6.2). Outside a scope nothing changes.

- [ ] **Step 1: Write the failing tests** (repository over `InMemoryEventStore`, which is not a participant; use the test aggregate/event types already in `Tests/EventSourcingTests/EventSourcingTests.swift` or copy a minimal pair):

```swift
// EventSourcingRepositoryUnitOfWorkTests
@Test func saveInsideScopeThrowsForNonParticipantStore()   // operationNotAllow, reason contains "InMemoryEventStore"
@Test func purgeInsideScopeThrowsForNonParticipantStore()
@Test func findInsideScopeWorksForNonParticipantStore()
@Test func saveOutsideScopeUnchanged()
@Test func errorThrownBySaveInsideScopeFailsTheScope()     // catch the operationNotAllow inside the block, return normally → withUnitOfWork throws commit-refused, cause is that error
@Test func errorThrownByFindInsideScopeFailsTheScope()     // store that throws from fetchEvents (a tiny EventStore double)
@Test func deleteOfMissingAggregateDoesNotFailTheScope()   // catch aggregateNotFound inside the block, return → withUnitOfWork returns normally, work.isFailed == false
// PersistentEventStoreUnitOfWorkTests (LocalEventStoreTests)
@Test func saveInsideScopeThrowsForPersistentEventStore()  // operationNotAllow; the file on disk is unchanged
@Test func findInsideScopeWorksForPersistentEventStore()
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter '(EventSourcingTests\.EventSourcingRepositoryUnitOfWorkTests|LocalEventStoreTests\.PersistentEventStoreUnitOfWorkTests)'`
Expected: `saveInsideScopeThrowsForNonParticipantStore` and the persistent variant FAIL (save succeeds today). The output shows a `Test run with N tests … failed` line per target with N > 0 (exit 0 with `warning: No matching test cases were run` means the filter matched nothing).

- [ ] **Step 3: Implement** the gate and the wrapping.

- [ ] **Step 4: Run the whole offline EventSourcing and LocalEventStore suites**

Run: `swift test --filter '(EventSourcingTests|LocalEventStoreTests)'`
Expected: PASS, including every pre-existing test untouched.

- [ ] **Step 5: Commit**

```bash
git add Sources/EventSourcing/EventSourcingRepository.swift Tests/EventSourcingTests/EventSourcingRepositoryUnitOfWorkTests.swift Tests/LocalEventStoreTests/PersistentEventStoreUnitOfWorkTests.swift
git commit -m "feat(event-sourcing): repositories gate non-participating stores and fail the unit of work on store errors"
```

---

### Task 6: `EventStoreClient` seam: `identity`, `appendAtomically`, DTOs

**Files:**
- Modify: `Sources/KurrentSupport/Adapter/EventStoreClient.swift` (protocol, extension default, `EventStoreClientError`)
- Create: `Sources/KurrentSupport/Adapter/StreamBatch.swift` (`StreamBatch`, `StreamBatchResult`, `StreamConflict`)
- Modify: `Sources/KurrentSupport/Adapter/LiveEventStoreClient.swift` (`identity`, `appendAtomically`)
- Modify: `Sources/KurrentSupportInMemory/InMemoryEventStoreClient.swift` (`identity`, `appendAtomically`)
- Modify: `Tests/KurrentSupportUnitTests/KurrentStorageCoordinatorErrorMappingTests.swift:31` and `Tests/KurrentSupportUnitTests/TombstoneDefaultTests.swift:8` (add `var identity: ObjectIdentifier { ObjectIdentifier(Self.self) }` to both struct doubles)
- Modify: `.github/workflows/swift-build-testing.yml:27,52` (add `KurrentSupportUnitTests` to both offline `--filter` lists)
- Test: `Tests/KurrentSupportUnitTests/AppendAtomicallyDefaultTests.swift`, `Tests/KurrentSupportInMemoryTests/InMemoryAppendAtomicallyTests.swift`

**Interfaces:**
- Produces:

```swift
public struct StreamBatch: Sendable { public let stream: String; public let category: String; public let expectedRevision: StreamRevision; public let events: [EventData]; public init(stream:category:expectedRevision:events:) }
public struct StreamBatchResult: Sendable, Equatable { public let stream: String; public let revision: UInt64; public init(stream:revision:) }
public struct StreamConflict: Sendable, Equatable { public let stream: String; public let expected: StreamRevision; public let current: UInt64?; public init(stream:expected:current:); public static func == (lhs: Self, rhs: Self) -> Bool }
// EventStoreClient
var identity: ObjectIdentifier { get }
func appendAtomically(_ batches: [StreamBatch]) async throws -> [StreamBatchResult]
// EventStoreClientError (stays Equatable)
case consistencyViolations([StreamConflict])
case atomicAppendUnsupported
```

- `StreamConflict.==` compares `stream`, `current`, and `expected` by a `switch` over `(.any, .any)`, `(.noStream, .noStream)`, `(.streamExists, .streamExists)`, `(.at(a), .at(b))` — `StreamRevision` is not `Equatable` and must not get a retroactive conformance.
- `LiveEventStoreClient.identity == ObjectIdentifier(client)` (the wrapped `KurrentDBClient`, a `final class`). `appendAtomically`: build `StreamEvent(stream: b.stream, records: try b.events.map(EventRecord.init(eventData:)), expectedRevision: b.expectedRevision)`; call `client.multiStreams.appendRecords(events:)`; map `KurrentError.consistencyViolation(violations:)` → `consistencyViolations` (expected from the batch with the same stream name; `current = actualState < 0 ? nil : UInt64(actualState)`); before building conflicts, if any violation has `actualState == -6` (tombstoned, §9) throw `KurrentError.resourceDeleted(resource: thatStream)` for the first such violation in batch order and nothing else (tombstone wins over revision conflicts; the server lists both with no precedence); `-5` (soft-deleted) and `-1` (missing) both become `current = nil`; other errors rethrown unchanged (`unsupportedFeature` is mapped by the backend, Task 7); return `response.revisions.map { .init(stream: $0.streamIdentifier.name, revision: $0.revision) }`.
- `InMemoryEventStoreClient` is an `actor`: declare `nonisolated public var identity: ObjectIdentifier { ObjectIdentifier(self) }`. `appendAtomically`: first run the existing `idempotentRevision(of:in:expected:)` for every batch; if **every** batch hits, return those revisions and write nothing (§6.5; a partially replayed request is not simulated and falls through). Then check every batch (tombstoned → `KurrentError.resourceDeleted(resource:)` for the first tombstoned batch, before any conflict is reported, matching the live seam; collect every expectedRevision mismatch using the same `switch` as `append` into `[StreamConflict]`; non-empty → throw `consistencyViolations`, write nothing); then write batches in order reusing `append`'s storing loop (extract it into a private helper), `globalSequenceCounter` continuing across batches, delivering to subscriptions per stream after all writes.

- [ ] **Step 1: Write the failing tests**

`AppendAtomicallyDefaultTests` (KurrentSupportUnitTests): a conformer without `appendAtomically` compiles (the deprecation warning is expected) and `appendAtomically([])` throws `EventStoreClientError.atomicAppendUnsupported`; `StreamConflict(stream: "a", expected: .at(1), current: nil) == StreamConflict(stream: "a", expected: .at(1), current: nil)` and `!= … expected: .at(2)`.

`InMemoryAppendAtomicallyTests` (KurrentSupportInMemoryTests):

```swift
@Test func twoNewStreamsGetRevisionZeroEach()                 // results contain (A,0) and (B,1) for 1 and 2 events; readStream shows them
@Test func allChecksBeforeAnyWrite()                          // A ok, B expected .at(3) but missing → consistencyViolations == [StreamConflict(B, .at(3), nil)], A not written
@Test func everyViolationReported()                           // both wrong → two conflicts
@Test func tombstonedStreamThrowsResourceDeletedAndWritesNothing()
@Test func tombstonedWinsOverConflict()                       // A tombstoned, B expected .at(3) but missing → resourceDeleted(A), not consistencyViolations
@Test func resendingEveryBatchReturnsOriginalRevisions()      // append [A,B] .noStream twice → same results, streams unchanged
@Test func partialResendIsAnOrdinaryConflict()                // resend A only plus new C → consistencyViolations for A, C not written
@Test func globalSequenceContinuesAcrossBatches()             // a $ce subscription receives A's then B's events in order
@Test func identityIsStablePerInstance()                      // same instance equal, two instances differ
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter '(KurrentSupportUnitTests\.AppendAtomicallyDefaultTests|KurrentSupportInMemoryTests\.InMemoryAppendAtomicallyTests)'`
Expected: FAIL to compile.

- [ ] **Step 3: Implement** the protocol additions, DTOs, both conformances, `identity` on the two test doubles, and the CI filter entries.

- [ ] **Step 4: Build everything and run the offline Kurrent suites**

Run: `swift build --build-tests && swift test --filter '(KurrentSupportUnitTests|KurrentSupportInMemoryTests)'`
Expected: PASS; the only new warnings are the intended deprecation on `LegacyClient` and on the new default-test conformer. Existing `#expect(throws: EventStoreClientError.tombstoneUnsupported)` tests still compile (Equatable kept).

- [ ] **Step 5: Commit**

```bash
git add Sources/KurrentSupport/Adapter/EventStoreClient.swift Sources/KurrentSupport/Adapter/StreamBatch.swift Sources/KurrentSupport/Adapter/LiveEventStoreClient.swift Sources/KurrentSupportInMemory/InMemoryEventStoreClient.swift Tests/KurrentSupportUnitTests Tests/KurrentSupportInMemoryTests/InMemoryAppendAtomicallyTests.swift .github/workflows/swift-build-testing.yml
git commit -m "feat(kurrent): EventStoreClient gains identity and atomic multi-stream append"
```

---

### Task 7: `KurrentUnitOfWorkBackend` and shared event encoding

**Files:**
- Create: `Sources/KurrentSupport/Adapter/KurrentEventEncoding.swift`
- Create: `Sources/KurrentSupport/Adapter/KurrentUnitOfWorkBackend.swift`
- Modify: `Sources/KurrentSupport/Adapter/KurrentStorageCoordinator.swift:52-61` (call the shared encoder; no behaviour change)
- Create: `Tests/KurrentSupportInMemoryTests/CountingClient.swift` (internal test helper: `final class CountingClient: EventStoreClient` forwarding every call to a wrapped `InMemoryEventStoreClient`, counting `append` / `appendAtomically` calls in a `Mutex<[String: Int]>`, with an optional `revisionOffset: UInt64` added to returned revisions and an optional `errorToThrow: (any Error)?` thrown by both append methods; `identity` forwards to the wrapped client's `identity`; Task 8 reuses it)
- Test: `Tests/KurrentSupportInMemoryTests/KurrentUnitOfWorkBackendTests.swift`

**Interfaces:**
- Consumes: `UnitOfWorkBackend` (Task 4); `EventStoreClient.append` / `.appendAtomically`, `StreamBatch`, `StreamConflict` (Task 6); `DDDError.commitConflict(conflicts:)` (Task 3).
- Produces (module KurrentSupport, `package`):

```swift
package func encodeForKurrent<Metadata: EventMetadata>(events: [any DomainEvent], metadata: Metadata?) throws -> (events: [EventData], metadataBytes: Data?)

package final class KurrentUnitOfWorkBackend: UnitOfWorkBackend {
    package init(client: any EventStoreClient)
    /// Returns the predicted tail revision: `.noStream` → count-1, `.at(n)` → n+count.
    /// Second stage on the same stream: `expectedRevision` must equal `.at(previousPredictedTail)`, else throws
    /// `DDDError.commitConflict(id:expected:actual: previousPredictedTail)`; on match appends to the batch, keeps the first expectedRevision.
    /// Throws `operationNotAllow` for empty events, for `.any` / `.streamExists`, and once `commit()` has started ("unit of work already committed").
    package func stage(id: String, stream: String, category: String, expectedRevision: StreamRevision, events: [EventData]) throws -> UInt64
    /// Staged events plus the revision the first one will get (`.noStream` → 0, `.at(n)` → n+1). Throws once committed.
    package func stagedEvents(stream: String) throws -> (firstRevision: UInt64, events: [EventData])?
    package func commit() async throws
}
```

- `commit()` (§6.4): mark `committed` first (inside the lock); 0 batches → return; 1 → `client.append(events:toStream:category:expectedRevision:)`; ≥2 → `client.appendAtomically`. Map errors: `EventStoreClientError.wrongExpectedRevision(current:)` and `KurrentError.wrongExpectedVersion` → `commitConflict(id:expected:actual:)` (expected = the batch's `.noStream` → nil / `.at(n)` → n); `consistencyViolations` → `commitConflict(conflicts:)` with each conflict's `id` looked up from the batch for that stream; `KurrentError.resourceDeleted(resource:)` → `streamPurged(id:)` for that stream; `KurrentError.unsupportedFeature` → `operationNotAllow(operation: "commit", reason: "server does not support AppendRecords (KurrentDB 26.1+)")`; `EventStoreClientError.atomicAppendUnsupported` and everything else rethrown unchanged. After success compare each returned revision with the predicted tail; a missing stream or a mismatch → `logger.warning` (label `"KurrentUnitOfWorkBackend"`, message names the stream, predicted and returned revision) and **return normally**. State in `Mutex<State>` with `[String: Batch]` plus an insertion-ordered key list so commit order is deterministic.

- [ ] **Step 1: Write the failing tests** (backend over `InMemoryEventStoreClient`; events built with `EventData(id:eventType:payload:customMetadata:)`):

```swift
@Test func stagePredictsTailForNewAndExistingStreams()        // .noStream + 3 events → 2; .at(4) + 1 → 5; stagedEvents firstRevision 0 and 5
@Test func secondStageMustFollowPredictedTail()               // .at(2) after predicted 2 → merged, returns 3; .at(1) → commitConflict(expected 1, actual 2)
@Test func stageRejectsEmptyAnyAndStreamExists()              // three operationNotAllow cases
@Test func commitWithNoBatchesTouchesNothing()
@Test func singleBatchUsesPlainAppend()                       // CountingClient: append == 1, appendAtomically == 0
@Test func twoBatchesUseAppendAtomically()
@Test func consistencyViolationsBecomeCommitConflictWithIds()  // pre-write stream A; stage A .noStream and B .noStream → commitConflicts == [CommitConflict(id:"a", expected:nil, actual:0)], B not written
@Test func tombstonedBecomesStreamPurged()
@Test func unsupportedFeatureBecomesOperationNotAllow()        // CountingClient(errorToThrow: KurrentError.unsupportedFeature(...))
@Test func revisionMismatchIsLoggedNotThrown()                 // CountingClient(revisionOffset: 10): commit returns normally; both streams written
@Test func stageAfterCommitThrows()                            // commit once, then stage → operationNotAllow "already committed"; stagedEvents also throws
@Test func encodeForKurrentMatchesCoordinatorOutput()          // append the same events+metadata through KurrentStorageCoordinator and through encodeForKurrent + client.append; readStream both; compare eventType, id, payload and customMetadata as JSON objects via JSONSerialization
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter 'KurrentSupportInMemoryTests\.KurrentUnitOfWorkBackendTests'`
Expected: FAIL to compile.

- [ ] **Step 3: Implement** the encoder, move the coordinator's inline encoding onto it, and implement the backend.

- [ ] **Step 4: Run the offline Kurrent suites plus the contract suite**

Run: `swift test --filter '(KurrentSupportInMemoryTests|KurrentSupportUnitTests|EventStoreContractTests)'`
Expected: PASS (the coordinator's outside-scope behaviour is unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/KurrentSupport/Adapter/KurrentEventEncoding.swift Sources/KurrentSupport/Adapter/KurrentUnitOfWorkBackend.swift Sources/KurrentSupport/Adapter/KurrentStorageCoordinator.swift Tests/KurrentSupportInMemoryTests/CountingClient.swift Tests/KurrentSupportInMemoryTests/KurrentUnitOfWorkBackendTests.swift
git commit -m "feat(kurrent): unit-of-work backend stages batches and commits via v1 or v2 append"
```

---

### Task 8: `KurrentStorageCoordinator` inside a scope

**Files:**
- Modify: `Sources/KurrentSupport/Adapter/KurrentStorageCoordinator.swift` (`append`, both `fetchEvents`, `purge`; `UnitOfWorkParticipant` conformance)
- Create: `Sources/KurrentSupport/Adapter/StagedRecordedEvent.swift` (`struct StagedRecordedEvent: RecordedEventLike`, built from an `EventData` plus `revision` and `streamName`; `decode` via `JSONDecoder` on `payload.data`)
- Test: `Tests/KurrentSupportInMemoryTests/KurrentStorageCoordinatorUnitOfWorkTests.swift`

**Interfaces:**
- Consumes: `UnitOfWork.current`, `backend(_:identity:make:)` (Task 4); `KurrentUnitOfWorkBackend`, `encodeForKurrent` (Task 7); `client.identity` (Task 6); swift-kurrentdb `EventRecord(eventData:)` for the carry check.
- Produces (§6.3): inside a scope (`UnitOfWork.current` read on every call, never cached on the coordinator) `append` = early-return on empty → huge-version check as today → `encodeForKurrent` → carry check: `for e in events { _ = try EventRecord(eventData: e) }`, skipped when `metadataBytes == nil`; a thrown error → `operationNotAllow(operation: "save", reason: "Metadata cannot be carried by AppendRecords: \(error)")` → `backend.stage(...)` → return predicted tail. `fetchEvents(byId:)` / `(byId:afterRevision:)` = read from client as today (treat `streamNotFound` / `resourceDeleted` as `[]` when staged events exist), then append `backend.stagedEvents(stream:)` wrapped as `StagedRecordedEvent` with revisions `firstRevision, firstRevision+1, …`, apply the `afterRevision` filter to the merged list, run the combined records through `eventMapper`; `latestRevision` is the last staged revision when any is staged. `purge` → `operationNotAllow(operation: "purge", reason: "not allowed inside a unit of work")`. `extension KurrentStorageCoordinator: UnitOfWorkParticipant {}`.

- [ ] **Step 1: Write the failing tests** (two aggregate types `Quoting`/`Billing` with their own `EventStreamNaming`, generated-style mappers that fill `event.metadata` from `customMetadata`, repositories as `struct … : EventSourcingRepository` over the coordinators, one shared `InMemoryEventStoreClient`; a `LegacyOnlyClient` double in this file that forwards `append`/`readStream` to an `InMemoryEventStoreClient` but relies on the deprecated `appendAtomically` default):

```swift
@Test func twoRepositoriesCommitTogether()                    // inside: both save; client sees no append until the block ends; after: both streams at revision 0, both aggregates version 0, events cleared
@Test func secondUsecaseSeesFirstUsecasesEvents()             // new stream: save 3 events; find same id → state reflects them, version == 2; save 1 more → one batch, 4 events, stream revision 3
@Test func findMergesStagedOntoExistingStream()               // outside: save 2 events (revisions 0–1); inside: save 1 → predicted 2; find → version 2, 3 events in order
@Test func fetchAfterRevisionIncludesStagedEvents()           // outside 2 events; inside stage 2; fetchEvents(byId:afterRevision: 1) → exactly the 2 staged with revisions 2, 3; afterRevision: 2 → 1 event
@Test func singleStreamScopeUsesV1Append()                    // CountingClient from Task 7: append == 1, appendAtomically == 0
@Test func oneStreamAlreadyWrittenConflictsAndWritesNeither() // commitConflicts lists that id; other stream absent; aggregates keep version/events (documented: do not reuse instances after a failed block)
@Test func bothStreamsConflictReportTwo()
@Test func purgedStreamThrowsStreamPurged()
@Test func purgeInsideScopeThrows()
@Test func differentClientInstancesCannotShareAScope()        // second coordinator on another InMemoryEventStoreClient → operationNotAllow on save
@Test func sameClientInstanceSharesABackend()                 // two coordinators, each wrapping its own CountingClient around the SAME InMemoryEventStoreClient → one backend; counters sum to one appendAtomically call; the KurrentDBClient convenience-init case is Task 9
@Test func metadataPerSaveTravelsWithItsEvents()              // two withValue scopes with different operatorId → each stream's customMetadata differs; find inside scope returns event.metadata filled
@Test func metadataNilStagesNoBytes()
@Test func uncarriableMetadataInsideScopeThrows()             // Metadata = a RawRepresentable String enum (encodes to a JSON scalar) → operationNotAllow at save; outside the scope it writes
@Test func hugeVersionInsideScopeIsCommitConflictWithoutStaging()
@Test func bodyThrowWritesNothing()
@Test func sameStreamFromTwoCoordinatorsConflicts()           // two StreamNamings yielding "Order-1": second save → commitConflict, scope failed
@Test func concurrentChildTasksStageIntoOneBackend()          // async let a = work that builds a Quoting inside the child and saves it, b = same for Billing → both streams committed; aggregates never cross the child-task boundary
@Test func escapedTaskAfterScopeEndThrowsAndWritesNothing()   // Task { await gate; try await repo.save(x) } started inside the block; after withUnitOfWork returned, open the gate → that save throws operationNotAllow "already ended"; client has no append for x
@Test func saveInsideHookWritesDirectly()                     // try work.onCommitted { try await repo.save(y) } → after the block y's stream exists; it was written by a plain append after the atomic commit
@Test func legacyClientTwoStreamsThrowsAtomicAppendUnsupported() // LegacyOnlyClient: two saves fine, withUnitOfWork throws EventStoreClientError.atomicAppendUnsupported, nothing written
@Test func outsideScopeBehaviourUnchanged()                    // append writes immediately; purge tombstones
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter 'KurrentSupportInMemoryTests\.KurrentStorageCoordinatorUnitOfWorkTests'`
Expected: `twoRepositoriesCommitTogether` FAILS (client receives appends immediately). The output shows `Test run with N tests … failed` with N > 0 (exit 0 with `warning: No matching test cases were run` means the filter matched nothing).

- [ ] **Step 3: Implement** per the Interfaces block.

- [ ] **Step 4: Run every offline suite that touches the coordinator**

Run: `swift test --filter '(KurrentSupportInMemoryTests|KurrentSupportUnitTests|EventStoreContractTests|EventSourcingTests|DDDKitUnitTests)'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/KurrentSupport/Adapter/KurrentStorageCoordinator.swift Sources/KurrentSupport/Adapter/StagedRecordedEvent.swift Tests/KurrentSupportInMemoryTests/KurrentStorageCoordinatorUnitOfWorkTests.swift
git commit -m "feat(kurrent): coordinator stages appends and merges reads inside withUnitOfWork"
```

---

### Task 9: Live KurrentDB tests for `withUnitOfWork`

**Files:**
- Modify: `Package.swift:186-194` (`KurrentLiveContractTests` gains the `DDDCore` dependency)
- Create: `Tests/KurrentLiveContractTests/UnitOfWorkLiveTests.swift`

**Interfaces:**
- Consumes: everything above through the public API only (`withUnitOfWork`, `KurrentStorageCoordinator(client: KurrentDBClient, eventMapper:)`, `KurrentProjection.PersistentSubscriptionRunner` or `LiveEventStoreClient.subscribePersistent` for the `$ce` check); `TestUtility.KurrentDBClient.withPooledIntegrationTestClient`; `LiveEventStoreClient.appendAtomically` directly for the seam-level suite.
- Produces: `struct SpikeMetadata: EventMetadata, Equatable { let s: String; let i: Int; let b: Bool; let d: Date; let o: String?; let n: Nested; struct Nested: Codable, Equatable { let k: String } }` in this file, used as the coordinators' `Metadata` type.

- [ ] **Step 1: Write the tests** (unique ids per run; two coordinators each built with the `KurrentDBClient` convenience init so the identity-sharing path is the one the user's apps use):

```swift
@Test func twoRepositoriesLandAtomically()           // both streams exist after the block, revision 0 each
@Test func conflictListsEveryStream()                // pre-write both streams → commitConflicts.count == 2, no new events
@Test func tombstonedStreamIsStreamPurged()
@Test func tombstonedNextToConflictIsStreamPurged()  // one stream tombstoned, the other pre-written → streamPurged (DDDKit precedence, spec §6.5), nothing new written
@Test func readBackThroughMapperMatchesWrite()       // fetchEvents after commit: eventType, payload, event.metadata (SpikeMetadata: s "x", i 7, b true, d Date(timeIntervalSince1970: 1_700_000_000), o nil, n.k "v") equal what was saved under EventMetadataContext; compare the decoded struct only — the server adds "$schema.name"/"$schema.format" keys to the raw bytes (§9)
@Test func softDeletedStreamRecreatedInScopeCommits() // outside: v1-write 3 events (revisions 0–2) then v1-delete; inside: save it with version nil plus another aggregate → block returns, hook ran, find(byId:) gives version 3 (old tail + 1, §9) — a revision-mismatch warning was logged, no error
@Test func categorySubscriptionReceivesUnitOfWorkEvents()  // ensure group on "$ce-<Category>", subscribe, run the block, receive both events (bounded wait ≤ 10 s)
```

Seam-level suite `LiveEventStoreClientAppendAtomicallyTests` in the same file, pinning the `actualState` encodings spec §9 records (unique stream names per run):

```swift
@Test func missingStreamUnderAtReportsCurrentNil()     // [E .noStream (E exists at 0), M .at(5) (M missing)] → consistencyViolations == [StreamConflict(E, .noStream, 0), StreamConflict(M, .at(5), nil)]
@Test func tombstonedStreamThrowsResourceDeleted()     // tombstone T; [T .noStream, U .noStream] → KurrentError.resourceDeleted(resource: T); U not written
@Test func tombstonedWinsOverConflict()                // tombstone T; pre-write C at 0; [C .noStream, T .noStream] → resourceDeleted(T), not consistencyViolations
@Test func resendingTheSameRecordIdsIsIdempotent()     // appendAtomically [A, B] twice with .noStream → identical results both times, each stream still has its original events
```

- [ ] **Step 2: Run against local KurrentDB** (pool URL exported as in Global Constraints)

Run: `swift test --filter KurrentLiveContractTests`
Expected: PASS (all live suites). A failure in `readBackThroughMapperMatchesWrite` means swift-kurrentdb 2.6.1's metadata fix does not hold on DDDKit's path: stop and report (the fix lives there). A failure in the seam-level suite means the server's `actualState` encoding differs from spec §9: stop and report, do not adapt the code silently.

- [ ] **Step 3: Commit**

```bash
git add Package.swift Tests/KurrentLiveContractTests/UnitOfWorkLiveTests.swift
git commit -m "test(kurrent): withUnitOfWork against a live KurrentDB 26.1"
```

---

### Task 10: Documentation and PR

**Files:**
- Modify: `README.md` (`## Flow` ASCII diagram near line 61: add one line "compose usecases with `withUnitOfWork`"; a new short section after "Save and Find" with spec §5.2 and the block rules from §5.6)
- Modify: `CLAUDE.md` (Key Protocols: add a `withUnitOfWork` / `UnitOfWork` entry summarising §6.2–§6.4 in the same voice as the `EventStore` contract entry, including close-on-return, hooks outside the scope, log-only revision mismatch; Build & Test: `KurrentLiveContractTests` now also covers `UnitOfWorkLiveTests` and `LiveEventStoreClientAppendAtomicallyTests`, and the `KURRENTDB_POOL_URLS` line; Layer Structure: `EventSourcing` line mentions `UnitOfWork`)
- Modify: `MIGRATION.md` (new `## 1.5.0` section in the 1.4.0 format: SB entries for `EventStoreClient.identity`, the two `EventStoreClientError` cases, the swift-kurrentdb floor; behaviour notes from spec §8's last paragraph, plus the metadata precision note from spec §9: inside a scope metadata travels as protobuf `Value`, so integers beyond ±2^53 are rounded to the nearest Double — store such values as strings)
- Create: `docs/migration/swift-ddd-kit-1.4-to-1.5.html` (copy the structure of `swift-ddd-kit-1.3-to-1.4.html`; same SB list as `MIGRATION.md`, plus "behaviour inside a scope", the block rules, "projection runs on subscription runners, not inside a scope")
- Modify: `docs/index.html` (doc-card near line 655 and footer near line 693 link the new migration page; the "What's new" release block is added when 1.5.0 ships, not here)
- Create: `Sources/EventSourcing/EventSourcing.docc/UnitOfWork.md` and `Sources/KurrentSupport/KurrentSupport.docc/UnitOfWork.md` (one article each, spec §5 for the first, §6.3–§6.5 for the second — the KurrentSupport article also carries the metadata rules from spec §9: must be a JSON object, NaN/infinity/over-64-bit integers fail at `save`, integers beyond ±2^53 are rounded, the server adds `$schema.*` keys on read; the documentation workflow picks `.docc` catalogs up automatically)

- [ ] **Step 1: Write the docs** using the spec's wording; code samples must compile against the real API names from Tasks 4–8 (`try work.onCommitted`, `try work.fail`).

- [ ] **Step 2: Verify the README snippet compiles** by pasting it into a scratch test in `Tests/KurrentSupportInMemoryTests` and running `swift build --build-tests`, then delete the scratch test. Run `scripts/emit-symbol-graphs.sh` once to confirm the two new `.docc` catalogs do not break the docs build.

- [ ] **Step 3: Commit**

```bash
git add README.md CLAUDE.md MIGRATION.md docs/migration/swift-ddd-kit-1.4-to-1.5.html docs/index.html Sources/EventSourcing/EventSourcing.docc Sources/KurrentSupport/KurrentSupport.docc
git commit -m "docs: describe withUnitOfWork and the 1.5 EventStoreClient changes"
```

- [ ] **Step 4: Open the PR** (never merge, never push to `main`): `git push -u origin feat/unit-of-work` then `gh pr create --title "feat: withUnitOfWork — atomic multi-aggregate writes" --body-file -` with a body that links the spec and plan, lists the SB items and the block rules, and ends with the attribution lines. Stop there; merging is the user's call.
