# Ambient Context & Pluggable Metadata Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce typed ambient metadata propagation (`EventMetadataContext<M>` + `EventMetadata` marker protocol) to replace the existing `external: [String:String]?` dict channel on `EventSourcingRepository.save` and `EventStore.append`. Metadata flows via TaskLocal from Usecase entry to KurrentDB `customMetadata` bytes; read path uses generator-produced mapper to populate `event.metadata`.

**Architecture:** Two-side integration. **Write side**: Usecase sets `EventMetadataContext<M>.$current.withValue(...)`; `Repository.save` default impl reads ambient and passes typed `Metadata?` to `EventStore.append`; `KurrentStorageCoordinator` JSON-encodes it into `EventData.customMetadata`. **Read side**: existing per-event `DomainEvent.Metadata` mechanism is preserved; generator-produced mapper decodes `record.customMetadata` bytes and assigns to `event.metadata`. Compile-time consistency between `Store.Metadata` and `event.Metadata` is by convention (generator default `typealias Metadata = CustomMetadata`).

**Tech Stack:** Swift 6.0, swift-testing, KurrentDB swift client. macOS 15+ / iOS 16+.

**Prerequisites:**
- The working-tree rename changes (`EventStorageCoordinator` → `EventStore` protocol, `var coordinator` → `var store`, `associatedtype Storage` → `associatedtype Store`) MUST be committed before starting this plan. Run `git status` first; if those changes are uncommitted, commit them as a separate prep commit using the repo's `[REFACTOR]` style. Until that's done, the file paths and signatures below won't match disk.
- Reference spec: `docs/superpowers/specs/2026-05-15-ambient-context-and-pluggable-metadata-design.md`

**File Structure:**
- **New files**:
  - `Sources/EventSourcing/EventMetadata.swift` — `EventMetadata` marker protocol
  - `Sources/EventSourcing/EventMetadataContext.swift` — `EventMetadataContext<M>` TaskLocal carrier
  - `Tests/EventSourcingTests/EventMetadataContextTests.swift` — TaskLocal behaviour tests
  - `Tests/EventSourcingTests/EventSourcingRepositoryMetadataTests.swift` — Repository → ambient → store metadata flow tests
- **Modified files**:
  - `Sources/EventSourcing/EventStorageCoordinator/EventStorageCoordinator.swift` — add `associatedtype Metadata`, swap `append`'s `external` for typed `metadata`
  - `Sources/EventSourcing/EventStorageCoordinator/InMemoryStorageCoordinator.swift` — add `Metadata` generic param, store metadata side-by-side with events
  - `Sources/EventSourcing/EventSourcingRepository.swift` — drop `external` from `save`/`delete`, default `save` reads `EventMetadataContext<Store.Metadata>.current`
  - `Sources/KurrentSupport/Adapter/KurrentStorageCoordinator.swift` — add `Metadata` generic param, encode typed metadata to `EventData.customMetadata`
  - `Sources/KurrentSupport/Adapter/CustomMetadata.swift` — add `: EventMetadata` conformance
  - `Sources/DomainEventGenerator/Generator/EventMapper/EventMapperGenerator.swift` — guard against empty `customMetadata`, use `try?` for metadata decode
  - All test files referencing `InMemoryStorageCoordinator`, `KurrentStorageCoordinator`, or `repository.save(aggregateRoot:, external:)`
  - All `samples/*/Sources/main.swift` referencing the above
  - `README.md`, `CLAUDE.md`, `MIGRATION.md`

---

## Task 1: Add `EventMetadata` Marker Protocol

**Files:**
- Create: `Sources/EventSourcing/EventMetadata.swift`

- [ ] **Step 1: Create the file with the protocol**

```swift
// Sources/EventSourcing/EventMetadata.swift
import Foundation

/// Marker protocol for application-defined event metadata schemas.
///
/// Applications define concrete metadata structs by conforming to this protocol;
/// the framework imposes no schema fields. Together with `EventMetadataContext`,
/// this is the write-side channel that replaces the legacy `external: [String:String]?`
/// parameter on `EventSourcingRepository.save` / `EventStore.append`.
///
/// Example:
/// ```swift
/// struct AuditMetadata: EventMetadata {
///     let operatorId: String
///     let tenantId: String
/// }
/// ```
public protocol EventMetadata: Codable, Sendable {}
```

- [ ] **Step 2: Verify the build compiles**

Run: `swift build --target EventSourcing`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/EventSourcing/EventMetadata.swift
git commit -m "$(cat <<'EOF'
[FEATURE] Add EventMetadata marker protocol

Codable + Sendable marker for application-defined event metadata schemas.
Framework imposes no schema fields. Foundation for ambient context propagation.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add `EventMetadataContext<M>` TaskLocal Carrier + Tests

**Files:**
- Create: `Sources/EventSourcing/EventMetadataContext.swift`
- Create: `Tests/EventSourcingTests/EventMetadataContextTests.swift`

- [ ] **Step 1: Write failing tests for TaskLocal behaviour**

```swift
// Tests/EventSourcingTests/EventMetadataContextTests.swift
import Foundation
import Testing
@testable import EventSourcing

private struct TestAuditMeta: EventMetadata, Equatable {
    let operatorId: String
}

private struct OtherMeta: EventMetadata, Equatable {
    let tenantId: String
}

@Suite("EventMetadataContext")
struct EventMetadataContextTests {

    @Test("withValue inside closure exposes the set value")
    func withValueExposes() async throws {
        await EventMetadataContext<TestAuditMeta>.$current.withValue(TestAuditMeta(operatorId: "u1")) {
            #expect(EventMetadataContext<TestAuditMeta>.current == TestAuditMeta(operatorId: "u1"))
        }
    }

    @Test("After withValue returns, current is back to nil")
    func currentRestoresAfterScope() async throws {
        await EventMetadataContext<TestAuditMeta>.$current.withValue(TestAuditMeta(operatorId: "u1")) {
            _ = EventMetadataContext<TestAuditMeta>.current
        }
        #expect(EventMetadataContext<TestAuditMeta>.current == nil)
    }

    @Test("Nested withValue overrides; outer restored on inner exit")
    func nestedOverride() async throws {
        await EventMetadataContext<TestAuditMeta>.$current.withValue(TestAuditMeta(operatorId: "outer")) {
            await EventMetadataContext<TestAuditMeta>.$current.withValue(TestAuditMeta(operatorId: "inner")) {
                #expect(EventMetadataContext<TestAuditMeta>.current?.operatorId == "inner")
            }
            #expect(EventMetadataContext<TestAuditMeta>.current?.operatorId == "outer")
        }
    }

    @Test("Different M types have independent storage slots")
    func independentSlotsPerType() async throws {
        await EventMetadataContext<TestAuditMeta>.$current.withValue(TestAuditMeta(operatorId: "u1")) {
            await EventMetadataContext<OtherMeta>.$current.withValue(OtherMeta(tenantId: "t1")) {
                #expect(EventMetadataContext<TestAuditMeta>.current?.operatorId == "u1")
                #expect(EventMetadataContext<OtherMeta>.current?.tenantId == "t1")
            }
        }
    }

    @Test("Structured async let inherits the ambient context")
    func structuredAsyncLetInherits() async throws {
        let result = await EventMetadataContext<TestAuditMeta>.$current.withValue(TestAuditMeta(operatorId: "u1")) {
            async let observed = EventMetadataContext<TestAuditMeta>.current
            return await observed
        }
        #expect(result?.operatorId == "u1")
    }

    @Test("Task.detached does NOT inherit ambient context")
    func detachedTaskDoesNotInherit() async throws {
        let detachedValue: TestAuditMeta? = await EventMetadataContext<TestAuditMeta>.$current.withValue(TestAuditMeta(operatorId: "u1")) {
            await Task.detached { EventMetadataContext<TestAuditMeta>.current }.value
        }
        #expect(detachedValue == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter EventMetadataContextTests`
Expected: FAIL — `EventMetadataContext` not defined.

- [ ] **Step 3: Create the implementation**

```swift
// Sources/EventSourcing/EventMetadataContext.swift
import Foundation

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
    @TaskLocal public static var current: M?
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter EventMetadataContextTests`
Expected: PASS — all 6 tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/EventSourcing/EventMetadataContext.swift \
        Tests/EventSourcingTests/EventMetadataContextTests.swift
git commit -m "$(cat <<'EOF'
[FEATURE] Add EventMetadataContext<M> TaskLocal carrier

Generic enclosing enum gives each Metadata type an independent TaskLocal
slot — no runtime as? cast needed at read site. Tests cover withValue
scoping, nested override, per-type slot independence, async let
inheritance, and Task.detached non-inheritance.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Make `CustomMetadata` Conform to `EventMetadata`

**Files:**
- Modify: `Sources/KurrentSupport/Adapter/CustomMetadata.swift`

- [ ] **Step 1: Add the conformance**

Edit `Sources/KurrentSupport/Adapter/CustomMetadata.swift`. Find:

```swift
public struct CustomMetadata: Codable, Sendable {
```

Replace with:

```swift
import EventSourcing

public struct CustomMetadata: Codable, Sendable, EventMetadata {
```

(Keep the rest of the file — `className`, `external`, `operatorId` extension — unchanged.)

- [ ] **Step 2: Verify the build compiles**

Run: `swift build --target KurrentSupport`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/KurrentSupport/Adapter/CustomMetadata.swift
git commit -m "$(cat <<'EOF'
[FEATURE] CustomMetadata conforms to EventMetadata

CustomMetadata is the default schema used by generator-produced events
(typealias Metadata = CustomMetadata). Conformance to EventMetadata makes
it usable as the Store.Metadata type via EventMetadataContext<CustomMetadata>.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Refactor `EventStore` Protocol & `InMemoryStorageCoordinator`

This task changes the `EventStore` protocol shape and the in-memory implementation atomically. It does NOT yet change `KurrentStorageCoordinator` or `EventSourcingRepository` — those follow in Tasks 5 and 6. **Between this task's commit and Task 5's, the build will be broken** because `KurrentStorageCoordinator` still conforms with the old signature. That's acceptable — the next two tasks form an unavoidable refactor sequence.

**Files:**
- Modify: `Sources/EventSourcing/EventStorageCoordinator/EventStorageCoordinator.swift`
- Modify: `Sources/EventSourcing/EventStorageCoordinator/InMemoryStorageCoordinator.swift`

- [ ] **Step 1: Replace the `EventStore` protocol**

Edit `Sources/EventSourcing/EventStorageCoordinator/EventStorageCoordinator.swift`. Replace the whole file with:

```swift
import DDDCore
import Foundation

public protocol EventStore: Sendable {
    associatedtype Metadata: EventMetadata

    func fetchEvents(byId id: String) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)?
    func fetchEvents(byId id: String, afterRevision revision: UInt64) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)?
    func append(
        events: [any DomainEvent],
        byId id: String,
        version: UInt64?,
        metadata: Metadata?
    ) async throws -> UInt64?
    func purge(byId id: String) async throws
}

extension EventStore {
    /// Default: fetches all events then drops those already processed.
    /// Suitable for count-based revision schemes. Stores with different
    /// revision semantics (e.g. 0-based index) should override for correctness.
    public func fetchEvents(byId id: String, afterRevision revision: UInt64) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)? {
        guard let result = try await fetchEvents(byId: id) else { return nil }
        let newEvents = Array(result.events.dropFirst(Int(revision)))
        return (events: newEvents, latestRevision: result.latestRevision)
    }
}
```

- [ ] **Step 2: Replace `InMemoryStorageCoordinator`**

Edit `Sources/EventSourcing/EventStorageCoordinator/InMemoryStorageCoordinator.swift`. Replace the whole file with:

```swift
import DDDCore
import Foundation

/// A thread-safe, in-memory implementation of `EventStore`.
/// Suitable for testing, prototyping, or use cases that do not require persistence.
///
/// Stores typed metadata side-by-side with events. `fetchEvents` returns events
/// as appended — it does NOT populate `event.metadata` on read (the heterogeneous
/// `[any DomainEvent]` makes generic typed assignment impractical). Tests that
/// need to verify metadata round-trip should either inspect the store's
/// `recordedMetadata(byId:)` helper or use the Kurrent integration tests.
public actor InMemoryStorageCoordinator<Metadata: EventMetadata>: EventStore {

    private struct Entry {
        var events: [any DomainEvent]
        var metadata: [Metadata?]   // 1:1 with events; one entry per appended event
        var revision: UInt64
    }

    private var store: [String: Entry] = [:]

    public init() {}

    public func fetchEvents(byId id: String) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)? {
        guard let entry = store[id] else { return nil }
        return (events: entry.events, latestRevision: entry.revision)
    }

    public func fetchEvents(byId id: String, afterRevision revision: UInt64) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)? {
        guard let entry = store[id] else { return nil }
        let startIndex = Int(revision)
        guard startIndex <= entry.events.count else { return nil }
        let newEvents = Array(entry.events[startIndex...])
        return (events: newEvents, latestRevision: entry.revision)
    }

    public func append(
        events: [any DomainEvent],
        byId id: String,
        version: UInt64?,
        metadata: Metadata?
    ) async throws -> UInt64? {
        let existing = store[id]?.events ?? []
        let existingMetadata = store[id]?.metadata ?? []
        if let expectedVersion = version, let currentRevision = store[id]?.revision {
            guard currentRevision == expectedVersion else {
                throw InMemoryStorageCoordinatorError.versionConflict(
                    expected: expectedVersion, actual: currentRevision
                )
            }
        }
        let newMetadata = existingMetadata + Array(repeating: metadata, count: events.count)
        let newRevision = UInt64(existing.count + events.count)
        store[id] = Entry(
            events: existing + events,
            metadata: newMetadata,
            revision: newRevision
        )
        return newRevision
    }

    public func purge(byId id: String) async throws {
        store.removeValue(forKey: id)
    }

    // MARK: - Test inspection helpers

    /// Returns the metadata associated with each appended event (1:1, ordered).
    /// Test-only — production code should not depend on this.
    public func recordedMetadata(byId id: String) async -> [Metadata?] {
        store[id]?.metadata ?? []
    }
}

public enum InMemoryStorageCoordinatorError: Error {
    case versionConflict(expected: UInt64, actual: UInt64)
}
```

- [ ] **Step 3: Verify only EventSourcing target compiles (others will break)**

Run: `swift build --target EventSourcing`
Expected: `Build complete!` (other targets — KurrentSupport, tests — will fail; that's intentional)

- [ ] **Step 4: Commit** (note that the rest of the package won't build until Tasks 5 + 6)

```bash
git add Sources/EventSourcing/EventStorageCoordinator/EventStorageCoordinator.swift \
        Sources/EventSourcing/EventStorageCoordinator/InMemoryStorageCoordinator.swift
git commit -m "$(cat <<'EOF'
[REFACTOR] EventStore.append accepts typed metadata; InMemory adopts generic Metadata

BREAKING CHANGE: EventStore.append's external: [String:String]? parameter is
replaced with metadata: Metadata? where Metadata is a new EventStore
associatedtype constrained to EventMetadata. InMemoryStorageCoordinator
becomes generic over Metadata and records appended metadata 1:1 with events.

KurrentStorageCoordinator and EventSourcingRepository conform on the OLD
signature; they are migrated in the next two commits — the package will not
build cleanly until those land.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Update `KurrentStorageCoordinator` to New `EventStore` Signature

**Files:**
- Modify: `Sources/KurrentSupport/Adapter/KurrentStorageCoordinator.swift`

- [ ] **Step 1: Replace the `KurrentStorageCoordinator` class**

Edit `Sources/KurrentSupport/Adapter/KurrentStorageCoordinator.swift`. Replace the whole file with:

```swift
import DDDCore
import EventSourcing
import KurrentDB
import Foundation
import Logging

fileprivate struct EventWrapped: Sendable {
    let event: any DomainEvent
    let revision: UInt64
}

public final class KurrentStorageCoordinator<
    StreamNaming: EventStreamNaming,
    Metadata: EventMetadata
>: EventStore {
    let logger = Logger(label: "KurrentStorageCoordinator")
    let eventMapper: any EventTypeMapper
    let client: KurrentDBClient

    public init(client: KurrentDBClient, eventMapper: any EventTypeMapper) {
        self.eventMapper = eventMapper
        self.client = client
    }

    public func append(
        events: [any DDDCore.DomainEvent],
        byId id: String,
        version: UInt64?,
        metadata: Metadata?
    ) async throws -> UInt64? {
        let streamName = StreamNaming.getStreamName(id: id)
        let encoder = JSONEncoder()
        let metadataBytes: Data
        if let metadata {
            metadataBytes = try encoder.encode(metadata)
        } else {
            metadataBytes = Data()
        }
        let eventDataList = try events.map { event in
            try EventData(
                id: event.id,
                eventType: event.eventType,
                model: event,
                customMetadata: metadataBytes
            )
        }
        let stream = client.streams(specified: streamName)
        let response = try await stream.append(events: eventDataList) {
            $0.expectedRevision = version.map { .at(UInt64($0)) } ?? .any
        }
        return response.currentRevision.flatMap { UInt64($0) }
    }

    public func fetchEvents(byId id: String) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)? {
        let streamName = StreamNaming.getStreamName(id: id)
        do {
            let stream = client.streams(specified: streamName)
            let recordEvents = try await stream.read {
                $0.direction = .forward
                $0.revision = .start
                $0.resolveLinks = true
            }.map { response in
                try response.event.record
            }.reduce(.init()) { partialResult, event in
                return partialResult + [event]
            }

            let eventWrappers: [EventWrapped] = recordEvents.reduce(into: .init()) {
                do {
                    guard let event = try self.eventMapper.mapping(eventData: $1) else {
                        return
                    }
                    $0.append(.init(event: event, revision: $1.revision))
                } catch {
                    logger.warning("skipped event cause error happened. error: \(error)")
                    return
                }
            }

            guard let latestRevision = eventWrappers.last?.revision else {
                return nil
            }

            let events = eventWrappers.map(\.event)
            let sortedEvents = events.sorted {
                $0.occurred < $1.occurred
            }

            return (events: sortedEvents, latestRevision: latestRevision)
        } catch KurrentError.resourceNotFound(let reason) {
            logger.warning("Skip an error happened in esdb, with reason: \(reason)")
            return nil
        } catch {
            logger.error("The error happened when fetching events: \(error)")
            throw error
        }
    }

    public func fetchEvents(byId id: String, afterRevision revision: UInt64) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)? {
        let streamName = StreamNaming.getStreamName(id: id)
        do {
            let stream = client.streams(specified: streamName)
            let recordEvents = try await stream.read {
                $0.direction = .forward
                $0.revision = .specified(revision + 1)
                $0.resolveLinks = true
            }.map { response in
                try response.event.record
            }.reduce(.init()) { partialResult, event in
                return partialResult + [event]
            }

            let eventWrappers: [EventWrapped] = recordEvents.reduce(into: .init()) {
                do {
                    guard let event = try self.eventMapper.mapping(eventData: $1) else {
                        return
                    }
                    $0.append(.init(event: event, revision: $1.revision))
                } catch {
                    logger.warning("skipped event cause error happened. error: \(error)")
                    return
                }
            }

            guard let latestRevision = eventWrappers.last?.revision else {
                return (events: [], latestRevision: revision)
            }

            let sortedEvents = eventWrappers.map(\.event).sorted {
                $0.occurred < $1.occurred
            }

            return (events: sortedEvents, latestRevision: latestRevision)
        } catch KurrentError.resourceNotFound(let reason) {
            logger.warning("Skip an error happened in esdb, with reason: \(reason)")
            return nil
        } catch {
            logger.error("The error happened when fetching events: \(error)")
            throw error
        }
    }

    public func purge(byId id: String) async throws {
        let streamName = StreamNaming.getStreamName(id: id)
        try await self.client.streams(specified: streamName).delete()
    }
}
```

Key differences from previous version:
- Added second generic param `Metadata: EventMetadata`
- `append` signature: `external: [String:String]?` → `metadata: Metadata?`
- `append` body: JSON-encode `metadata` (if non-nil) into `customMetadata`; the old `CustomMetadata(className:external:)` wrapper is gone — apps that want className round-trip use `CustomMetadata` AS their `Metadata` type (route Q from the spec)
- `fetchEvents` bodies are unchanged — mapper handles per-event metadata decode

- [ ] **Step 2: Verify only EventSourcing + KurrentSupport targets compile**

Run: `swift build --target KurrentSupport`
Expected: `Build complete!` (Repository default impl + tests + samples still break — fixed in Task 6)

- [ ] **Step 3: Commit**

```bash
git add Sources/KurrentSupport/Adapter/KurrentStorageCoordinator.swift
git commit -m "$(cat <<'EOF'
[REFACTOR] KurrentStorageCoordinator adopts Metadata generic and typed append

BREAKING CHANGE: KurrentStorageCoordinator gains a Metadata: EventMetadata
generic param; append takes typed metadata: Metadata? and JSON-encodes it
into EventData.customMetadata bytes. The legacy CustomMetadata(className:,
external:) wrapper on the write path is removed — applications using
CustomMetadata as their schema get className via CustomMetadata itself
(route Q from the design spec).

Repository default impl + tests + samples still reference the old
signatures; next commit migrates them.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Migrate `EventSourcingRepository` to Ambient Context

**Files:**
- Modify: `Sources/EventSourcing/EventSourcingRepository.swift`

- [ ] **Step 1: Replace `EventSourcingRepository`**

Edit `Sources/EventSourcing/EventSourcingRepository.swift`. Replace the whole file with:

```swift
import DDDCore
import Foundation

public protocol EventSourcingRepository<Store>: Repository {
    associatedtype Store: EventStore

    var store: Store { get }

    func find(byId id: AggregateRootType.ID) async throws -> AggregateRootType?
    func save(aggregateRoot: AggregateRootType) async throws
}

extension EventSourcingRepository {
    public func find(byId id: AggregateRootType.ID) async throws -> AggregateRootType? {
        return try await self.find(byId: id, hiddingDeleted: true)
    }

    public func find(byId id: AggregateRootType.ID, hiddingDeleted: Bool) async throws -> AggregateRootType? {

        guard let fetchEventsResult = try await store.fetchEvents(byId: id) else {
            return nil
        }

        let events = fetchEventsResult.events

        guard !(hiddingDeleted && (events.contains { $0 is AggregateRootType.DeletedEventType })) else {
            return nil
        }

        let deletedEvent = events.first {
            $0 is AggregateRootType.DeletedEventType
        } as? AggregateRootType.DeletedEventType

        //濾掉 AggregateRootType 是 AggregateRootType.DeletedEventType 的 Event
        let aggregateRoot = try AggregateRootType(events: events.filter{ !($0 is AggregateRootType.DeletedEventType) })

        if let deletedEvent {
            try aggregateRoot?.markDelete()
            try aggregateRoot?.apply(event: deletedEvent)
        }

        aggregateRoot?.update(version: fetchEventsResult.latestRevision)

        try aggregateRoot?.clearAllDomainEvents()

        return aggregateRoot
    }

    public func save(aggregateRoot: AggregateRootType) async throws {
        let metadata = EventMetadataContext<Store.Metadata>.current
        let latestRevision: UInt64? = try await store.append(
            events: aggregateRoot.events,
            byId: aggregateRoot.id,
            version: aggregateRoot.version,
            metadata: metadata
        )
        if let latestRevision {
            aggregateRoot.update(version: latestRevision)
        }
        try aggregateRoot.clearAllDomainEvents()
    }

    public func delete(byId id: AggregateRootType.ID) async throws {
        guard let aggregateRoot = try await find(byId: id) else {
            throw DDDError.aggregateNotFound(usecase: "DeleteAggregateRoot", aggregateRootType: AggregateRootType.self, aggregateRootId: "\(id)")
        }

        try aggregateRoot.markDelete()
        try await save(aggregateRoot: aggregateRoot)
    }

    /// 危險操作!! 完全移除，不可恢復
    public func purge(byId id: AggregateRootType.ID) async throws {
        guard let _ = try await find(byId: id) else {
            throw DDDError.aggregateNotFound(usecase: "DeleteAggregateRoot", aggregateRootType: AggregateRootType.self, aggregateRootId: "\(id)")
        }
        try await store.purge(byId: id)
    }
}
```

Key differences:
- `save`'s `external: [String:String]?` parameter removed
- `delete`'s `external: [String:String]?` parameter removed
- `save` default impl reads `EventMetadataContext<Store.Metadata>.current` and passes typed `metadata` to `store.append`

- [ ] **Step 2: Verify the full package now compiles**

Run: `swift build`
Expected: `Build complete!` — first time since Task 4 the whole package compiles

(Tests will still fail because test stubs use old signatures. Fixed in Tasks 7–8.)

- [ ] **Step 3: Commit**

```bash
git add Sources/EventSourcing/EventSourcingRepository.swift
git commit -m "$(cat <<'EOF'
[REFACTOR] EventSourcingRepository.save reads EventMetadataContext

BREAKING CHANGE: Repository.save and Repository.delete drop the
external: [String:String]? parameter. The save default impl now reads
EventMetadataContext<Store.Metadata>.current and forwards it as typed
metadata to store.append.

Test stubs and samples still pass the old parameter; next two tasks
migrate them.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Migrate Test Files to New Signatures

**Files:**
- Modify: `Tests/DDDKitUnitTests/EventSourcingRepositoryTests.swift`
- Modify: `Tests/KurrentSupportUnitTests/KurrentProjectionRunnerSetupTests.swift`
- Modify: `Tests/KurrentSupportUnitTests/KurrentProjectionTransactionalRunnerSetupTests.swift`
- Modify: `Tests/ReadModelPersistenceTests/StatefulProjectorTests.swift`
- Modify: `Tests/KurrentSupportIntegrationTests/KurrentProjectionTransactionalRunnerIntegrationTests.swift`

- [ ] **Step 1: Update `EventSourcingRepositoryTests.swift` — InMemoryCoordinator + ItemRepository + call sites**

In `Tests/DDDKitUnitTests/EventSourcingRepositoryTests.swift`:

Find the `InMemoryCoordinator` private class and change its conformance from `EventStore` to typed:

```swift
private final class InMemoryCoordinator: EventStore {
```

becomes:

```swift
private final class InMemoryCoordinator: EventStore {
    typealias Metadata = CustomMetadata
```

Then change the `append` signature:

```swift
func append(events: [any DomainEvent], byId id: String, version: UInt64?, external: [String: String]?) async throws -> UInt64? {
```

becomes:

```swift
func append(events: [any DomainEvent], byId id: String, version: UInt64?, metadata: CustomMetadata?) async throws -> UInt64? {
```

Replace the `external` param body usage (`appendCallCount += 1` etc. stays). The body's reference to `external` should be removed; nothing else needed.

Add `import KurrentSupport` to the top imports if not present (for `CustomMetadata`).

Then update every `ItemRepository.save(aggregateRoot: ..., external: ...)` and `ItemRepository.delete(byId: ..., external: ...)` call site to remove the `external:` argument:

- `try await repo.save(aggregateRoot: item, external: nil)` → `try await repo.save(aggregateRoot: item)`
- `try await repo.delete(byId: "item-1", external: nil)` → `try await repo.delete(byId: "item-1")`

(Use grep to find all `external:` usages in this file and update them.)

- [ ] **Step 2: Update `KurrentProjectionRunnerSetupTests.swift` — StubCoordinator**

In `Tests/KurrentSupportUnitTests/KurrentProjectionRunnerSetupTests.swift`:

Find:

```swift
private struct StubCoordinator: EventStore {
    func fetchEvents(byId id: String) async throws -> (events: [any DomainEvent], latestRevision: UInt64)? { nil }
    func fetchEvents(byId id: String, afterRevision revision: UInt64) async throws -> (events: [any DomainEvent], latestRevision: UInt64)? { nil }
    func append(events: [any DomainEvent], byId id: String, version: UInt64?, external: [String : String]?) async throws -> UInt64? { nil }
    func purge(byId id: String) async throws {}
}
```

Replace with:

```swift
private struct StubCoordinator: EventStore {
    typealias Metadata = CustomMetadata
    func fetchEvents(byId id: String) async throws -> (events: [any DomainEvent], latestRevision: UInt64)? { nil }
    func fetchEvents(byId id: String, afterRevision revision: UInt64) async throws -> (events: [any DomainEvent], latestRevision: UInt64)? { nil }
    func append(events: [any DomainEvent], byId id: String, version: UInt64?, metadata: CustomMetadata?) async throws -> UInt64? { nil }
    func purge(byId id: String) async throws {}
}
```

- [ ] **Step 3: Update `KurrentProjectionTransactionalRunnerSetupTests.swift` — StubCoordinator**

Same change as Step 2 — find the identical `StubCoordinator` struct and apply the same edit.

- [ ] **Step 4: Update `StatefulProjectorTests.swift` — InMemoryStorageCoordinator instantiations**

In `Tests/ReadModelPersistenceTests/StatefulProjectorTests.swift`:

Find every `InMemoryStorageCoordinator()` call (5 sites — lines around 60, 88, 123, 146, 214, 234, 249 per earlier audit) and replace with `InMemoryStorageCoordinator<CustomMetadata>()`. Also update the property declaration on `TestProjector`:

Find:

```swift
typealias Store = InMemoryStorageCoordinator

static var categoryRule: StreamCategoryRule { .custom("Test") }

let store: InMemoryStorageCoordinator
```

Replace with:

```swift
typealias Store = InMemoryStorageCoordinator<CustomMetadata>

static var categoryRule: StreamCategoryRule { .custom("Test") }

let store: InMemoryStorageCoordinator<CustomMetadata>
```

Add `import KurrentSupport` if needed for `CustomMetadata`.

- [ ] **Step 5: Update `KurrentProjectionTransactionalRunnerIntegrationTests.swift` — DemoProjector**

In `Tests/KurrentSupportIntegrationTests/KurrentProjectionTransactionalRunnerIntegrationTests.swift`:

Find:

```swift
typealias Store = KurrentStorageCoordinator<DemoProjector>

static var categoryRule: StreamCategoryRule { .custom("TxDemo") }
let store: KurrentStorageCoordinator<DemoProjector>
```

Replace with:

```swift
typealias Store = KurrentStorageCoordinator<DemoProjector, CustomMetadata>

static var categoryRule: StreamCategoryRule { .custom("TxDemo") }
let store: KurrentStorageCoordinator<DemoProjector, CustomMetadata>
```

Find every `KurrentStorageCoordinator<DemoProjector>(client: kdb, eventMapper: ...)` call and replace with `KurrentStorageCoordinator<DemoProjector, CustomMetadata>(client: kdb, eventMapper: ...)`.

- [ ] **Step 6: Verify the package + tests build**

Run: `swift build && swift test --filter DDDKitUnitTests`
Expected: build + DDDKitUnitTests passes (other test targets that depend on samples may still fail — fixed in Task 8)

- [ ] **Step 7: Commit**

```bash
git add Tests/DDDKitUnitTests/EventSourcingRepositoryTests.swift \
        Tests/KurrentSupportUnitTests/KurrentProjectionRunnerSetupTests.swift \
        Tests/KurrentSupportUnitTests/KurrentProjectionTransactionalRunnerSetupTests.swift \
        Tests/ReadModelPersistenceTests/StatefulProjectorTests.swift \
        Tests/KurrentSupportIntegrationTests/KurrentProjectionTransactionalRunnerIntegrationTests.swift
git commit -m "$(cat <<'EOF'
[REFACTOR] tests — migrate stubs and call sites to typed metadata

Update InMemoryCoordinator / StubCoordinator test fixtures with
typealias Metadata = CustomMetadata and the new append signature.
Replace InMemoryStorageCoordinator() with InMemoryStorageCoordinator<CustomMetadata>().
Replace KurrentStorageCoordinator<X>(...) with KurrentStorageCoordinator<X, CustomMetadata>(...).
Drop external: nil arguments from save / delete call sites.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Migrate Samples to Typed Metadata

**Files:**
- Modify: `samples/StatefulReadModelDemo/Sources/main.swift`
- Modify: `samples/PostgresReadModelDemo/Sources/main.swift`
- Modify: `samples/KurrentProjectionDemo/Sources/main.swift`
- Modify: `samples/KurrentTransactionalProjectionDemo/Sources/main.swift`

- [ ] **Step 1: Update `StatefulReadModelDemo`**

In `samples/StatefulReadModelDemo/Sources/main.swift`:

- Find `typealias Store = InMemoryStorageCoordinator` → replace with `typealias Store = InMemoryStorageCoordinator<CustomMetadata>`
- Find `let store: InMemoryStorageCoordinator` → replace with `let store: InMemoryStorageCoordinator<CustomMetadata>`
- Find `let coordinator = InMemoryStorageCoordinator()` (around line 75) → replace with `let coordinator = InMemoryStorageCoordinator<CustomMetadata>()`
- Add `import KurrentSupport` if not already present

- [ ] **Step 2: Update `PostgresReadModelDemo`**

In `samples/PostgresReadModelDemo/Sources/main.swift`: same pattern as Step 1.

- [ ] **Step 3: Update `KurrentProjectionDemo`**

In `samples/KurrentProjectionDemo/Sources/main.swift`:

For each of `OrderSummaryProjector`, `OrderTimelineProjector`, `OrderRegistryProjector`:
- Find `typealias Store = KurrentStorageCoordinator<X>` → replace with `typealias Store = KurrentStorageCoordinator<X, CustomMetadata>`
- Find `let store: KurrentStorageCoordinator<X>` → replace with `let store: KurrentStorageCoordinator<X, CustomMetadata>`

For each projector registration around line 181-188:
- Find `KurrentStorageCoordinator<X>(client: kdbClient, eventMapper: mapper)` → replace with `KurrentStorageCoordinator<X, CustomMetadata>(client: kdbClient, eventMapper: mapper)`

For the `appendCoordinator` local around line 237: same replacement.

- [ ] **Step 4: Update `KurrentTransactionalProjectionDemo`**

In `samples/KurrentTransactionalProjectionDemo/Sources/main.swift`: same pattern as Step 3 for `OrderSummaryProjector` and `OrderRegistryProjector`. Also includes the `OrderSummaryProjector.init(store:, failureGate:)` which already uses the `store:` label — no signature change needed there, just the type.

`appendCoordinator` local in this sample (around line 280) — also update to `KurrentStorageCoordinator<OrderSummaryProjector, CustomMetadata>(...)`.

- [ ] **Step 5: Verify build + run one sample to confirm it still works**

Run: `swift build`
Expected: `Build complete!`

Run: `swift run StatefulReadModelDemo 2>&1 | head -20`
Expected: demo runs without errors (compares to behaviour before refactor — should be identical)

- [ ] **Step 6: Commit**

```bash
git add samples/StatefulReadModelDemo/Sources/main.swift \
        samples/PostgresReadModelDemo/Sources/main.swift \
        samples/KurrentProjectionDemo/Sources/main.swift \
        samples/KurrentTransactionalProjectionDemo/Sources/main.swift
git commit -m "$(cat <<'EOF'
[REFACTOR] samples — adopt KurrentStorageCoordinator<X, CustomMetadata>

Update all four samples to the new generic signatures. Functional behaviour
unchanged — samples don't yet demonstrate ambient context (that comes in
the next task with the dedicated metadata sample).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Fix Generator Mapper Output (Empty Metadata Guard)

**Files:**
- Modify: `Sources/DomainEventGenerator/Generator/EventMapper/EventMapperGenerator.swift`

- [ ] **Step 1: Update the generator to guard empty bytes and use `try?`**

In `Sources/DomainEventGenerator/Generator/EventMapper/EventMapperGenerator.swift`, find the per-event case template (around line 36-45):

```swift
for eventName in eventNames {
    lines.append("""
    case "\(eventName)":
        try {
            guard var event = try eventData.decode(to: \(eventName).self) else { return nil }
            // handle metadata
            let decoder = JSONDecoder()
            event.metadata = try decoder.decode(\(eventName).Metadata.self, from: eventData.customMetadata)
            return event
        }()
""")
}
```

Replace the inner template so the generated code becomes:

```swift
for eventName in eventNames {
    lines.append("""
    case "\(eventName)":
        try {
            guard var event = try eventData.decode(to: \(eventName).self) else { return nil }
            // handle metadata — tolerate empty bytes (no ambient on write) and
            // decode failure (Store.Metadata ≠ event.Metadata mismatch) by
            // leaving event.metadata nil
            if !eventData.customMetadata.isEmpty {
                let decoder = JSONDecoder()
                event.metadata = try? decoder.decode(\(eventName).Metadata.self, from: eventData.customMetadata)
            }
            return event
        }()
""")
}
```

Two changes:
1. `if !eventData.customMetadata.isEmpty` guard — handles the no-ambient case (write side passed nil metadata → bytes are empty → previous code threw `dataCorrupted`)
2. `try?` on the decode itself — handles the Store.Metadata vs event.Metadata type mismatch case (silently leave nil)

- [ ] **Step 2: Build the package — generator changes don't take effect on already-generated code, but the plugin will regenerate on next build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Find any committed `*EventMapper.swift` that was previously generated (search `Sources/`)**

Run: `find /Users/gradyzhuo/Dropbox/Work/OpenSource/swift-ddd-kit/Sources -name "*EventMapper.swift" -type f`

Expected: any files printed are generator-output files that may be hand-committed (rare in this repo, but check).

If any such files exist with the old `try decoder.decode(...)` line, regenerate or manually patch them to use the new template. If `find` prints nothing, skip.

- [ ] **Step 4: Commit**

```bash
git add Sources/DomainEventGenerator/Generator/EventMapper/EventMapperGenerator.swift
git commit -m "$(cat <<'EOF'
[FIX] EventMapperGenerator — guard empty customMetadata, swallow type mismatch

Previously the generated mapper called try decoder.decode(...) unconditionally,
which threw and dropped the event when customMetadata was empty (no ambient
context set on write) or when Store.Metadata differed from event.Metadata.
Now: skip decode when bytes are empty, and use try? so a type mismatch
yields event.metadata = nil rather than discarding the event.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Add Repository → Ambient Context Integration Tests

**Files:**
- Create: `Tests/EventSourcingTests/EventSourcingRepositoryMetadataTests.swift`

- [ ] **Step 1: Write the test file**

```swift
// Tests/EventSourcingTests/EventSourcingRepositoryMetadataTests.swift
import Foundation
import Testing
@testable import DDDCore
@testable import EventSourcing

// MARK: - Fixtures

private struct TestMetadata: EventMetadata, Equatable {
    let operatorId: String
}

private struct WidgetCreated: DomainEvent {
    typealias Metadata = TestMetadata
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
    var metadata: TestMetadata? = nil
    var name: String
}

private final class Widget: AggregateRoot {
    struct WidgetDeleted: DeletedEvent {
        typealias Metadata = TestMetadata
        var id: UUID = .init()
        var occurred: Date = .now
        var aggregateRootId: String
        var metadata: TestMetadata? = nil
    }
    typealias DeletedEventType = WidgetDeleted

    let id: String
    private(set) var name: String = ""
    var metadata: AggregateRootMetadata = .init()

    init(id: String, name: String) throws {
        self.id = id
        try apply(event: WidgetCreated(aggregateRootId: id, name: name))
    }

    required init?(events: [any DomainEvent]) throws {
        guard let first = events.first as? WidgetCreated else { return nil }
        self.id = first.aggregateRootId
        try apply(events: events)
    }

    func when(happened event: some DomainEvent) throws {
        switch event {
        case let e as WidgetCreated: name = e.name
        case is WidgetDeleted: metadata.delete()
        default: break
        }
    }
}

private final class WidgetRepository: EventSourcingRepository {
    typealias AggregateRootType = Widget
    typealias Store = InMemoryStorageCoordinator<TestMetadata>

    let store: InMemoryStorageCoordinator<TestMetadata>

    init(store: InMemoryStorageCoordinator<TestMetadata>) {
        self.store = store
    }
}

// MARK: - Tests

@Suite("EventSourcingRepository × EventMetadataContext")
struct EventSourcingRepositoryMetadataTests {

    @Test("save inside withValue propagates metadata to the store")
    func saveWithAmbientMetadata() async throws {
        let store = InMemoryStorageCoordinator<TestMetadata>()
        let repo = WidgetRepository(store: store)
        let widget = try Widget(id: "w-1", name: "alpha")

        try await EventMetadataContext<TestMetadata>.$current.withValue(TestMetadata(operatorId: "u-42")) {
            try await repo.save(aggregateRoot: widget)
        }

        let recorded = await store.recordedMetadata(byId: "w-1")
        #expect(recorded == [TestMetadata(operatorId: "u-42")])
    }

    @Test("save outside withValue records nil metadata (no crash)")
    func saveWithoutAmbient() async throws {
        let store = InMemoryStorageCoordinator<TestMetadata>()
        let repo = WidgetRepository(store: store)
        let widget = try Widget(id: "w-2", name: "beta")

        try await repo.save(aggregateRoot: widget)

        let recorded = await store.recordedMetadata(byId: "w-2")
        #expect(recorded == [TestMetadata?.none])
    }

    @Test("Two saves under different withValue scopes record their respective metadata")
    func saveAcrossScopes() async throws {
        let store = InMemoryStorageCoordinator<TestMetadata>()
        let repo = WidgetRepository(store: store)
        let widget1 = try Widget(id: "w-3", name: "gamma")
        let widget2 = try Widget(id: "w-4", name: "delta")

        try await EventMetadataContext<TestMetadata>.$current.withValue(TestMetadata(operatorId: "alice")) {
            try await repo.save(aggregateRoot: widget1)
        }
        try await EventMetadataContext<TestMetadata>.$current.withValue(TestMetadata(operatorId: "bob")) {
            try await repo.save(aggregateRoot: widget2)
        }

        let recorded1 = await store.recordedMetadata(byId: "w-3")
        let recorded2 = await store.recordedMetadata(byId: "w-4")
        #expect(recorded1 == [TestMetadata(operatorId: "alice")])
        #expect(recorded2 == [TestMetadata(operatorId: "bob")])
    }

    @Test("Multiple events from one save share the same metadata bytes")
    func batchSaveSharesMetadata() async throws {
        let store = InMemoryStorageCoordinator<TestMetadata>()
        let repo = WidgetRepository(store: store)
        let widget = try Widget(id: "w-5", name: "first")
        // Append another event to the same aggregate so save flushes both
        try widget.apply(event: WidgetCreated(aggregateRootId: "w-5", name: "second"))

        try await EventMetadataContext<TestMetadata>.$current.withValue(TestMetadata(operatorId: "charlie")) {
            try await repo.save(aggregateRoot: widget)
        }

        let recorded = await store.recordedMetadata(byId: "w-5")
        #expect(recorded.count == 2)
        #expect(recorded.allSatisfy { $0 == TestMetadata(operatorId: "charlie") })
    }
}
```

- [ ] **Step 2: Run the new tests**

Run: `swift test --filter EventSourcingRepositoryMetadataTests`
Expected: PASS — all 4 tests green.

- [ ] **Step 3: Run the full test suite to confirm nothing else regressed**

Run: `swift test`
Expected: all tests pass (modulo integration tests that need a live KurrentDB / Postgres, which can be skipped per the repo's existing test policy).

- [ ] **Step 4: Commit**

```bash
git add Tests/EventSourcingTests/EventSourcingRepositoryMetadataTests.swift
git commit -m "$(cat <<'EOF'
[TEST] EventSourcingRepository × EventMetadataContext integration

Verify the write-side metadata flow end-to-end against InMemoryStorageCoordinator:
ambient set in withValue propagates through Repository.save into the store's
recorded metadata; no ambient yields nil; nested scopes are isolated; multiple
events in one save share the same metadata bytes.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: KurrentDB Metadata Round-Trip Integration Test

This task requires a running KurrentDB on `localhost` (matches existing integration-test policy — tests skip gracefully when unavailable).

**Files:**
- Create: `Tests/KurrentSupportIntegrationTests/KurrentMetadataRoundtripTests.swift`

- [ ] **Step 1: Inspect an existing integration test to mirror the test client / stream setup pattern**

Run: `head -80 Tests/KurrentSupportIntegrationTests/KurrentProjectionTransactionalRunnerIntegrationTests.swift`
Expected: shows `KurrentDBClient.makeIntegrationTestClient()` helper and the `DemoEvent` / `DemoEventMapper` fixture style. Reuse the same patterns.

- [ ] **Step 2: Write the integration test**

```swift
// Tests/KurrentSupportIntegrationTests/KurrentMetadataRoundtripTests.swift
import Foundation
import Testing
import DDDCore
import EventSourcing
import KurrentDB
@testable import KurrentSupport

// MARK: - Fixtures

private struct RoundtripEvent: DomainEvent {
    typealias Metadata = CustomMetadata
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
    var metadata: CustomMetadata? = nil
    var note: String
}

private struct RoundtripEventMapper: EventTypeMapper {
    init() {}
    func mapping(eventData: RecordedEvent) throws -> (any DomainEvent)? {
        guard eventData.mappingClassName == "RoundtripEvent" else { return nil }
        guard var event = try eventData.decode(to: RoundtripEvent.self) else { return nil }
        if !eventData.customMetadata.isEmpty {
            let decoder = JSONDecoder()
            event.metadata = try? decoder.decode(CustomMetadata.self, from: eventData.customMetadata)
        }
        return event
    }
}

private enum RoundtripStream: EventStreamNaming {
    static var category: String { "RoundtripDemo" }
    static func getStreamName(id: String) -> String { "\(category)-\(id)" }
}

// MARK: - Suite

@Suite("Kurrent metadata round-trip", .serialized)
struct KurrentMetadataRoundtripTests {

    @Test("metadata written via ambient context is recoverable via event.metadata on read")
    func ambientToCustomMetadataRoundtrip() async throws {
        let kdb = KurrentDBClient.makeIntegrationTestClient()
        let store = KurrentStorageCoordinator<RoundtripStream, CustomMetadata>(
            client: kdb,
            eventMapper: RoundtripEventMapper()
        )

        let aggregateId = UUID().uuidString
        let written = CustomMetadata(
            className: "RoundtripEvent",
            external: ["operatorId": "alice", "tenantId": "t-1"]
        )
        let event = RoundtripEvent(aggregateRootId: aggregateId, note: "hello")

        // Write side — ambient + repository-equivalent direct append
        try await EventMetadataContext<CustomMetadata>.$current.withValue(written) {
            let metadata = EventMetadataContext<CustomMetadata>.current
            _ = try await store.append(
                events: [event],
                byId: aggregateId,
                version: nil,
                metadata: metadata
            )
        }

        // Read side — mapper populates event.metadata
        guard let result = try await store.fetchEvents(byId: aggregateId) else {
            Issue.record("fetchEvents returned nil for aggregate \(aggregateId)")
            return
        }
        guard let readEvent = result.events.first as? RoundtripEvent else {
            Issue.record("First event is not RoundtripEvent")
            return
        }
        #expect(readEvent.metadata?.external?["operatorId"] == "alice")
        #expect(readEvent.metadata?.external?["tenantId"] == "t-1")
        #expect(readEvent.note == "hello")
    }

    @Test("no ambient context yields nil event.metadata on read")
    func noAmbientYieldsNilMetadata() async throws {
        let kdb = KurrentDBClient.makeIntegrationTestClient()
        let store = KurrentStorageCoordinator<RoundtripStream, CustomMetadata>(
            client: kdb,
            eventMapper: RoundtripEventMapper()
        )

        let aggregateId = UUID().uuidString
        let event = RoundtripEvent(aggregateRootId: aggregateId, note: "no meta")

        // No EventMetadataContext.withValue — metadata is nil
        _ = try await store.append(
            events: [event],
            byId: aggregateId,
            version: nil,
            metadata: nil
        )

        guard let result = try await store.fetchEvents(byId: aggregateId) else {
            Issue.record("fetchEvents returned nil")
            return
        }
        guard let readEvent = result.events.first as? RoundtripEvent else {
            Issue.record("First event is not RoundtripEvent")
            return
        }
        #expect(readEvent.metadata == nil)
    }
}
```

- [ ] **Step 3: Run the integration test (KurrentDB must be on localhost)**

Run: `swift test --filter KurrentMetadataRoundtripTests`
Expected: 2 tests pass. If KurrentDB isn't running, the test will fail at `makeIntegrationTestClient` connect — that's expected; document the prerequisite in the commit message.

- [ ] **Step 4: Commit**

```bash
git add Tests/KurrentSupportIntegrationTests/KurrentMetadataRoundtripTests.swift
git commit -m "$(cat <<'EOF'
[TEST] Kurrent metadata round-trip integration test

Verifies the full write/read pipeline against a real KurrentDB:
ambient CustomMetadata → typed append → customMetadata bytes →
mapper decode → event.metadata. Also verifies the nil-ambient path
yields event.metadata = nil rather than throwing on empty bytes
(the empty-guard added to EventMapperGenerator in the previous task).

Requires KurrentDB on localhost.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Update Documentation

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Create or Modify: `MIGRATION.md`

- [ ] **Step 1: Add an "Event Metadata Pattern" section to `README.md`**

In `README.md`, locate the "Core Concepts" section (search for `## Core Concepts` or similar — fall back to inserting after the existing "Architecture Overview" if no Core Concepts heading exists). Append the following subsection at the end of Core Concepts:

```markdown
### Event Metadata Pattern (Ambient Context)

Application-defined metadata flows from Usecase entry to KurrentDB via Swift's
TaskLocal. Domain types (`AggregateRoot`, `DomainEvent` schemas) stay free of
audit / request / tenant concerns.

```swift
// 1. Application defines its schema (or uses the bundled CustomMetadata)
struct AuditMetadata: EventMetadata {
    let operatorId: String
    let tenantId: String
}

// 2. Repository binds the schema via Store.Metadata
final class OrderRepository: EventSourcingRepository {
    typealias AggregateRootType = Order
    typealias Store = KurrentStorageCoordinator<OrderStreamNaming, AuditMetadata>
    let store: Store
    init(store: Store) { self.store = store }
}

// 3. Usecase sets the ambient at entry
struct PlaceOrderUsecase {
    let repository: OrderRepository
    func execute(input: Input) async throws -> Output {
        let meta = AuditMetadata(operatorId: input.operatorId, tenantId: input.tenantId)
        return try await EventMetadataContext<AuditMetadata>.$current.withValue(meta) {
            let order = try Order(id: input.orderId, customerId: input.customerId)
            try await repository.save(aggregateRoot: order)
            return Output(orderId: order.id)
        }
    }
}

// 4. Read-side reads event.metadata directly (filled by the generated mapper)
func apply(readModel: inout OrderActivity, events: [any DomainEvent]) {
    for event in events {
        if let created = event as? OrderCreated, let meta = created.metadata {
            readModel.lastOperator = meta.operatorId
        }
    }
}
```

`CustomMetadata` (in `KurrentSupport`) is the bundled default schema used by
generator-produced events. Apps can use it as-is or replace with a custom
`EventMetadata`-conforming struct.

**Limits:**
- `Task.detached` does NOT inherit ambient context. Capture and re-apply if you
  spawn detached work across a metadata boundary.
- All events in one `save` share one metadata payload (intentional; if you need
  per-event metadata, that usually signals an aggregate boundary issue).
- `Store.Metadata` and `event.Metadata` alignment is by convention, not compile-
  time. Runtime mismatch yields `event.metadata = nil` rather than a crash.
```

- [ ] **Step 2: Add the same pattern note to `CLAUDE.md`**

In `CLAUDE.md`, find the "Key Protocols" or "Event Sourcing Flow" section. Add this paragraph before the TODO section:

```markdown
### Event Metadata Pattern

Application metadata (audit info, request ids, tenant ids) flows via
`EventMetadataContext<M: EventMetadata>` — a generic TaskLocal carrier —
from Usecase entry to `EventStore.append` at the storage boundary.
`AggregateRoot` and `DomainEvent` schemas never see ambient metadata on the
write path; the generated mapper fills `event.metadata` on the read path so
ReadModel / Projector can consume it normally.

Key types:
- `EventMetadata` (`Sources/EventSourcing/EventMetadata.swift`) — marker
  protocol, Codable + Sendable. Framework imposes no schema fields.
- `EventMetadataContext<M>` (`Sources/EventSourcing/EventMetadataContext.swift`)
  — `@TaskLocal` per `M`. Independent storage per type.
- `EventStore.Metadata` — store-level type binding. `KurrentStorageCoordinator`
  carries `Metadata: EventMetadata` as a second generic param.
- `CustomMetadata` (`KurrentSupport`) — bundled default schema (className +
  external dict + operatorId convenience). Generator output uses it by default.

Repository.save default impl reads `EventMetadataContext<Store.Metadata>.current`
and passes typed `metadata` to `store.append`. Write-side `event.metadata` is
ignored; read-side mapper populates it from `record.customMetadata`.
```

- [ ] **Step 3: Create or update `MIGRATION.md`**

Check whether `MIGRATION.md` exists:

Run: `test -f /Users/gradyzhuo/Dropbox/Work/OpenSource/swift-ddd-kit/MIGRATION.md && echo EXISTS || echo MISSING`

**If it exists**, append a new section at the end:

**If it's missing**, create with the following content as the entire file:

```markdown
# Migration Guide

## 2026-05 — Ambient Context Replaces `external: [String:String]?`

`EventSourcingRepository.save(aggregateRoot:external:)` and
`EventStore.append(...,external:)` lose the `external` parameter. Metadata
now flows via `EventMetadataContext<M>` from Usecase entry. The protocol
also gains an `associatedtype Metadata: EventMetadata` on `EventStore`.

### Step 1 — Define your metadata schema (or use the bundled one)

If your existing code passed `["userId": "..."]`-style dicts, the simplest
migration is to keep using `CustomMetadata` (which already has `external`
and an `operatorId` convenience):

```swift
import KurrentSupport
// CustomMetadata: Codable, Sendable, EventMetadata — already conforms.
```

Or define your own:

```swift
struct AuditMetadata: EventMetadata {
    let operatorId: String
    let tenantId: String
}
```

### Step 2 — Update Repository conformances

Add `Metadata` to your store's generic parameters:

```diff
- typealias Store = KurrentStorageCoordinator<OrderStreamNaming>
+ typealias Store = KurrentStorageCoordinator<OrderStreamNaming, CustomMetadata>
```

```diff
- let store: KurrentStorageCoordinator<OrderStreamNaming>
+ let store: KurrentStorageCoordinator<OrderStreamNaming, CustomMetadata>
```

Same for `InMemoryStorageCoordinator`:

```diff
- typealias Store = InMemoryStorageCoordinator
+ typealias Store = InMemoryStorageCoordinator<CustomMetadata>
```

### Step 3 — Update call sites

```diff
- try await repository.save(aggregateRoot: order, external: ["userId": userId])
+ try await EventMetadataContext<CustomMetadata>.$current.withValue(
+     CustomMetadata(className: "Order", external: ["userId": userId])
+ ) {
+     try await repository.save(aggregateRoot: order)
+ }
```

For `delete`, same removal of `external:`:

```diff
- try await repository.delete(byId: id, external: nil)
+ try await repository.delete(byId: id)
```

### Step 4 — Adopt ambient at Usecase entry (recommended)

The intended use is to set `EventMetadataContext` once at the Usecase entry,
so the rest of the body (and any nested repository / aggregate work) inherits
it via structured concurrency.

### Behavioural notes

- `Task.detached` does NOT inherit TaskLocal — capture and re-apply if needed.
- Multiple events in one `save` share one metadata payload.
- `Store.Metadata` and `event.Metadata` alignment is by convention; runtime
  mismatch yields `event.metadata = nil` on read, not a crash.
```

- [ ] **Step 4: Verify the spec file path referenced by the plan stays accurate**

Run: `test -f /Users/gradyzhuo/Dropbox/Work/OpenSource/swift-ddd-kit/docs/superpowers/specs/2026-05-15-ambient-context-and-pluggable-metadata-design.md && echo OK || echo MISSING`

Expected: `OK`. If the spec moved or was renamed, update the README/CLAUDE.md/MIGRATION.md cross-references accordingly.

- [ ] **Step 5: Commit**

```bash
git add README.md CLAUDE.md MIGRATION.md
git commit -m "$(cat <<'EOF'
[DOC] document Event Metadata Pattern + migration steps

README gets a new "Event Metadata Pattern" subsection under Core Concepts
showing the full write/read pattern. CLAUDE.md gets an in-codebase note
for future Claude sessions. MIGRATION.md (created or appended) gives
step-by-step diffs for callers updating from external: [String:String]?.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Final Verification

- [ ] **Step 1: Run full test suite**

Run: `swift test 2>&1 | tail -20`
Expected: all unit + read-model tests green. KurrentDB / Postgres integration tests may be skipped if those services aren't running locally — that's fine.

- [ ] **Step 2: Inspect the public API for Kurrent type leaks**

Run: `grep -rn "RecordedEvent\|EventData\|KurrentDB" --include="*.swift" Sources/EventSourcing/ Sources/DDDCore/`
Expected: zero matches. The `EventSourcing` and `DDDCore` modules should never reference Kurrent types — those stay inside `KurrentSupport`.

- [ ] **Step 3: Verify no remaining `external: [String:String]?` references**

Run: `grep -rn "external: \[String:String\]" --include="*.swift" Sources/ Tests/ samples/`
Expected: zero matches. (The `CustomMetadata.external` field is `external: [String: String]?` with a space — different pattern; it should still appear, that's fine.)

- [ ] **Step 4: Confirm `swift build` shows zero warnings**

Run: `swift build 2>&1 | grep -i "warning" | head -10`
Expected: empty output.

---

## Self-Review Checklist

Before declaring the plan done, the executing engineer should confirm:

- [ ] Every spec section in `2026-05-15-ambient-context-and-pluggable-metadata-design.md` is implemented:
  - `EventMetadata` marker → Task 1
  - `EventMetadataContext<M>` → Task 2
  - `CustomMetadata: EventMetadata` → Task 3
  - `EventStore.append` typed metadata → Task 4
  - `InMemoryStorageCoordinator<Metadata>` → Task 4
  - `KurrentStorageCoordinator<S, M>` → Task 5
  - `EventSourcingRepository` reads ambient → Task 6
  - All callers updated → Tasks 7–8
  - Generator empty-bytes guard + `try?` → Task 9
  - Unit + Repository tests → Tasks 2, 10
  - Kurrent integration round-trip test → Task 11
  - Docs (README + CLAUDE.md + MIGRATION.md) → Task 12
- [ ] No `try decoder.decode(...Metadata.self, from: ...)` without `try?` in generated mapper output
- [ ] No `external: [String:String]?` parameters in public API
- [ ] Public API of `EventSourcing` + `DDDCore` modules contains no Kurrent types
