# EventStore Contract (A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `EventStore` one written contract (0-based revisions, `nil` = new stream, `DDDError.commitConflict`, permanent `purge`, id-idempotent resend), make `InMemoryEventStore` and `KurrentStorageCoordinator` follow it, and prove it with a shared contract-test target.

**Architecture:** The contract follows what `KurrentStorageCoordinator` already does; only the points where the two stores disagree get decided. New `DDDError` codes live in DDDCore. `RecordedEventLike`/`EventTypeMapper`/`CustomMetadata` move down to EventSourcing (KurrentSupport keeps typealiases). An internal target `EventStoreContract` holds one throwing `check…` function per rule; each backend runs them from a single `@Test`. The Kurrent path only catches errors KurrentDB already throws and purges with `tombstone(.any)`.

**Tech Stack:** Swift 6.1+, swift-testing, swift-kurrentdb, SwiftPM.

**Spec:** `docs/superpowers/specs/2026-10-23-eventstore-contract-design.md` (rev 4). B (`PersistentEventStore`) and C (CI/platform) have their own plans and depend on this one.

**Worktree:** `.claude/worktrees/eventstore-contract` (branch `feat/eventstore-contract`, based on `main` at `016572d`). Run every command from that directory.

## Global Constraints

- Revisions are 0-based. `append` with empty `events` returns `nil` before any other rule. `version == nil` requires no stream; `version == n` requires tail `== n`.
- Conflict → `DDDError.commitConflict` (501) with `CommitConflict { id, expected, actual }`. Purged → `DDDError.streamPurged` (502). Codes 503/504 are added now, used by B.
- `purge` is permanent for any id, including ids never written. Repeated `purge` succeeds silently.
- Do not add mechanisms the spec removed (§9): no seam error-normalisation table, no new link-stream rules, no public conformance product, no `Testing` import in `EventStoreContract`.
- Never run bare `swift test`. Every run in this plan is `--filter`ed and needs no KurrentDB. Live-KurrentDB verification belongs to plan C (`KurrentLiveContractTests`).
- Code, comments and commit messages in English; commit style `feat(scope): …` / `refactor(scope): …` / `test(scope): …`.
- Every commit ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Never merge the PR or push to `main`.

## Review Focus

1. **Idempotent resend vs. conflict** — same ids at the expected position must return the original last revision without writing; any id difference (including partial overlap) must be `commitConflict`. Pinned by `checkIdempotentResend`.
2. **Purge of an id that never existed** — must succeed and make the id unwritable (`streamPurged`). Pinned by `checkPurge`.
3. **Empty append on a purged/conflicting stream** — must still return `nil`, not throw. Pinned by `checkEmptyAppendIsNoOp`.
4. **Tail made of events the mapper can't read** — `latestRevision` stays at the last mapped event, so `append(version: lastMapped)` conflicts with `actual` = real tail. Pinned by `checkUnmappedEventsAreSkipped`.
5. **External `EventStoreClient` conformers** — still compile; `purge` through them throws `tombstoneUnsupported` at run time. Pinned in Task 8.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/DDDCore/Adapter/DDDError.swift` (modify) | Codes 501–504, `CommitConflict`, `commitConflict`/`streamPurged` factories, accessor |
| `Sources/EventSourcing/Record/RecordedEventLike.swift` (create, moved) | Record abstraction |
| `Sources/EventSourcing/Record/EventTypeMapper.swift` (create, moved) | Mapper protocol |
| `Sources/EventSourcing/Record/CustomMetadata.swift` (create, moved) | Bundled metadata schema |
| `Sources/KurrentSupport/Adapter/EventTypeMapper.swift`, `CustomMetadata.swift`, `EventStoreClient.swift` (modify) | Typealiases to the moved types; `tombstoneStream`; `tombstoneUnsupported` |
| `Sources/KurrentSupport/Adapter/LiveEventStoreClient.swift` (modify) | `@retroactive` conformance; `tombstoneStream` |
| `Sources/DomainEventGenerator/Generator/Common/GeneratedImports.swift` (create) | Default imports of generated files, testable |
| `Sources/generate/Event.swift`, `EventMapper.swift`, `ProjectionModel.swift` (modify) | Use `GeneratedImports` |
| `Sources/EventSourcing/EventStorageCoordinator/InMemoryEventStore.swift` (rename from `InMemoryStorageCoordinator.swift`) | Contract-following in-memory store + deprecated old names |
| `Sources/EventStoreContract/ContractFixtures.swift` (create) | Events, metadata, stream naming, mapper used by the rules |
| `Sources/EventStoreContract/EventStoreContract.swift` (create) | One throwing `check…` per rule + `checkAll` |
| `Tests/EventStoreContractTests/EventStoreContractTests.swift` (create) | One `@Test` per backend |
| `Sources/KurrentSupportInMemory/InMemoryEventStoreClient.swift` (modify) | Tombstone, id idempotency |
| `Sources/KurrentSupport/Adapter/KurrentStorageCoordinator.swift` (modify) | Contract behaviour on the Kurrent path |
| `Sources/EventSourcing/EventSourcingRepository.swift` (modify) | `save` early return, `purge` direct |
| `Package.swift`, `scripts/emit-symbol-graphs.sh` (modify) | New targets; exclude `EventStoreContract` from docs |

---

### Task 0: Worktree and specs

**Files:** none in code.

- [ ] **Step 1: Create the worktree**

```bash
git worktree add .claude/worktrees/eventstore-contract -b feat/eventstore-contract main
cd .claude/worktrees/eventstore-contract
```

- [ ] **Step 2: Bring the specs and this plan in and commit them**

The four spec files and this plan are untracked in the main checkout.

```bash
for f in docs/superpowers/specs/2026-10-22-local-event-store-design.md \
         docs/superpowers/specs/2026-10-23-eventstore-contract-design.md \
         docs/superpowers/specs/2026-10-23-persistent-event-store-design.md \
         docs/superpowers/specs/2026-10-23-eventstore-ci-platform-design.md \
         docs/superpowers/plans/2026-10-24-eventstore-contract.md; do
  cp "../../../$f" "$f"
done
git add docs/superpowers
git commit -m "docs(specs): EventStore contract, local store and CI/platform specs

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 3: Baseline build**

Run: `swift build --build-tests`
Expected: `Build complete!`

---

### Task 1: `DDDError` store codes

**Files:**
- Modify: `Sources/DDDCore/Adapter/DDDError.swift:23-30` and append an extension
- Test: `Tests/DDDKitUnitTests/DDDErrorStoreCodesTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import DDDCore

@Suite("DDDError store codes")
struct DDDErrorStoreCodesTests {

    @Test("store codes are 501–504")
    func rawValues() {
        #expect(DDDError.Code.commitConflict.rawValue == 501)
        #expect(DDDError.Code.streamPurged.rawValue == 502)
        #expect(DDDError.Code.storeUnavailable.rawValue == 503)
        #expect(DDDError.Code.storeCorrupted.rawValue == 504)
    }

    @Test("commitConflict carries id, expected and actual")
    func commitConflictPayload() {
        let error = DDDError.commitConflict(id: "o-1", expected: nil, actual: 3)
        #expect(error.code == .commitConflict)
        #expect(error.commitConflict == DDDError.CommitConflict(id: "o-1", expected: nil, actual: 3))
    }

    @Test("commitConflict accessor is nil for other codes")
    func accessorNilForOtherCodes() {
        #expect(DDDError.streamPurged(id: "o-1").commitConflict == nil)
    }

    @Test("streamPurged carries the id")
    func streamPurgedPayload() {
        let error = DDDError.streamPurged(id: "o-1")
        #expect(error.code == .streamPurged)
        #expect(error.userInfos["id"] as? String == "o-1")
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `swift test --filter DDDErrorStoreCodesTests`
Expected: compile error, `type 'DDDError.Code' has no member 'commitConflict'`.

- [ ] **Step 3: Implement**

In `DDDError.Code` add after `case eventsNotFound = 401`:

```swift
        case commitConflict = 501
        case streamPurged = 502
        case storeUnavailable = 503
        case storeCorrupted = 504
```

Append to the file:

```swift
// MARK: - EventStore errors

extension DDDError {
    /// Payload of a `commitConflict` error: the stream's tail revision did not
    /// match what the caller expected. `nil` means "no stream".
    ///
    /// Diagnostic only — do not show it to end users verbatim.
    public struct CommitConflict: Sendable, Equatable {
        public let id: String
        public let expected: UInt64?
        public let actual: UInt64?

        public init(id: String, expected: UInt64?, actual: UInt64?) {
            self.id = id
            self.expected = expected
            self.actual = actual
        }
    }

    /// `EventStore.append` found the stream somewhere other than `expected`.
    /// Nothing was written.
    public static func commitConflict(id: String, expected: UInt64?, actual: UInt64?) -> Self {
        let errorCode = DDDError.Code.commitConflict
        let conflict = CommitConflict(id: id, expected: expected, actual: actual)
        let expectedText = expected.map { "\($0)" } ?? "no stream"
        let actualText = actual.map { "\($0)" } ?? "no stream"
        let message = "[\(errorCode)] Append to \(id) expected \(expectedText) but found \(actualText)."
        return .init(code: errorCode, message: message, userInfos: ["commitConflict": conflict])
    }

    /// The conflict details when `code == .commitConflict`, otherwise `nil`.
    public var commitConflict: CommitConflict? {
        guard code == .commitConflict else { return nil }
        return userInfos["commitConflict"] as? CommitConflict
    }

    /// `EventStore.append` targeted an id that was purged. Nothing was written,
    /// and the id can never be written again.
    public static func streamPurged(id: String) -> Self {
        let errorCode = DDDError.Code.streamPurged
        let message = "[\(errorCode)] \(id) was purged and cannot be written again."
        return .init(code: errorCode, message: message, userInfos: ["id": id])
    }
}
```

- [ ] **Step 4: Run it and confirm it passes**

Run: `swift test --filter DDDErrorStoreCodesTests`
Expected: 4 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/DDDCore/Adapter/DDDError.swift Tests/DDDKitUnitTests/DDDErrorStoreCodesTests.swift
git commit -m "feat(core): add EventStore error codes 501-504

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Move the record abstractions to EventSourcing

**Files:**
- Create (moved): `Sources/EventSourcing/Record/RecordedEventLike.swift`, `Sources/EventSourcing/Record/EventTypeMapper.swift`, `Sources/EventSourcing/Record/CustomMetadata.swift`
- Modify: `Sources/KurrentSupport/Adapter/EventStoreClient.swift:14-27`, `Sources/KurrentSupport/Adapter/EventTypeMapper.swift`, `Sources/KurrentSupport/Adapter/CustomMetadata.swift`, `Sources/KurrentSupport/Adapter/LiveEventStoreClient.swift:14-16`
- Test: `Tests/DDDKitUnitTests/RecordAbstractionsTests.swift` (`DDDKitUnitTests` does not depend on KurrentSupport, so it compiles only once the types live in EventSourcing)

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import DDDCore
import EventSourcing

private struct ProbeRecord: RecordedEventLike {
    let id = UUID()
    let eventType = "Probe"
    let revision: UInt64 = 0
    let customMetadata = Data()
    let streamName = "Probe-1"
    func decode<T: Decodable>(to type: T.Type) throws -> T? { nil }
}

private struct ProbeMapper: EventTypeMapper {
    func mapping(eventData: any RecordedEventLike) throws -> (any DomainEvent)? { nil }
}

@Suite("Record abstractions live in EventSourcing")
struct RecordAbstractionsTests {
    @Test("mapper, record and CustomMetadata are usable without KurrentSupport")
    func usableWithoutKurrentSupport() throws {
        let mapper: any EventTypeMapper = ProbeMapper()
        #expect(try mapper.mapping(eventData: ProbeRecord()) == nil)
        #expect(CustomMetadata(operatorId: "u-1").operatorId == "u-1")
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `swift test --filter RecordAbstractionsTests`
Expected: compile error, `cannot find type 'RecordedEventLike' in scope`.

- [ ] **Step 3: Move the files**

```bash
mkdir -p Sources/EventSourcing/Record
git mv Sources/KurrentSupport/Adapter/EventTypeMapper.swift Sources/EventSourcing/Record/EventTypeMapper.swift
git mv Sources/KurrentSupport/Adapter/CustomMetadata.swift Sources/EventSourcing/Record/CustomMetadata.swift
```

`Sources/EventSourcing/Record/EventTypeMapper.swift` — drop the `import EventSourcing` line (it is now in this module):

```swift
//
//  EventTypeMapper.swift
//
//
//  Created by Grady Zhuo on 2024/6/6.
//

import DDDCore
import Foundation

public protocol EventTypeMapper: Sendable {
    func mapping(eventData: any RecordedEventLike) throws -> (any DomainEvent)?
}
```

`Sources/EventSourcing/Record/CustomMetadata.swift`:

```swift
public struct CustomMetadata: EventMetadata {
    public let operatorId: String

    public init(operatorId: String) {
        self.operatorId = operatorId
    }
}
```

Create `Sources/EventSourcing/Record/RecordedEventLike.swift` with the protocol cut from `EventStoreClient.swift`:

```swift
import Foundation

/// A single stored/delivered event, decoupled from any concrete store's record type.
public protocol RecordedEventLike: Sendable {
    var id: UUID { get }
    var eventType: String { get }
    var revision: UInt64 { get }
    var customMetadata: Data { get }
    /// Name of the stream this event was originally appended to — e.g. `"Order-42"`,
    /// even when delivered via a resolved `$ce-Order` category-projection link.
    var streamName: String { get }
    func decode<T: Decodable>(to type: T.Type) throws -> T?
}
```

- [ ] **Step 4: Leave typealiases in KurrentSupport**

In `Sources/KurrentSupport/Adapter/EventStoreClient.swift`, replace lines 14–27 (imports + the `RecordedEventLike` protocol) with:

```swift
import EventSourcing
import Foundation
import KurrentDB

/// Moved to EventSourcing in 1.5; kept here so existing `KurrentSupport` imports compile.
public typealias RecordedEventLike = EventSourcing.RecordedEventLike
```

Create `Sources/KurrentSupport/Adapter/EventTypeMapper.swift`:

```swift
import EventSourcing

/// Moved to EventSourcing in 1.5; kept here so existing `KurrentSupport` imports compile.
public typealias EventTypeMapper = EventSourcing.EventTypeMapper
```

Create `Sources/KurrentSupport/Adapter/CustomMetadata.swift`:

```swift
import EventSourcing

/// Moved to EventSourcing in 1.5; kept here so existing `KurrentSupport` imports compile.
public typealias CustomMetadata = EventSourcing.CustomMetadata
```

In `Sources/KurrentSupport/Adapter/LiveEventStoreClient.swift` replace lines 10–16 with:

```swift
import EventSourcing
import Foundation
import KurrentDB
import Synchronization

extension RecordedEvent: @retroactive RecordedEventLike {
    public var streamName: String { streamIdentifier.name }
}
```

- [ ] **Step 5: Build everything and run the test**

Run: `swift build --build-tests`
Expected: `Build complete!` with no ambiguity errors (a typealias to the same type is not ambiguous when both modules are imported).

Run: `swift test --filter RecordAbstractionsTests`
Expected: 1 test passed.

- [ ] **Step 6: Commit**

```bash
git add -A Sources/EventSourcing/Record Sources/KurrentSupport Tests/DDDKitUnitTests/RecordAbstractionsTests.swift
git commit -m "refactor(event-sourcing): move RecordedEventLike, EventTypeMapper and CustomMetadata down from KurrentSupport

KurrentSupport keeps typealiases, so existing imports compile unchanged.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Generated files import EventSourcing

**Files:**
- Create: `Sources/DomainEventGenerator/Generator/Common/GeneratedImports.swift`
- Modify: `Sources/generate/Event.swift:48`, `Sources/generate/EventMapper.swift:60`, `Sources/generate/ProjectionModel.swift:59`
- Test: `Tests/DomainEventGeneratorTests/GeneratedImportsTests.swift`

- [ ] **Step 1: Write the failing golden test**

```swift
import Testing
@testable import DomainEventGenerator

@Suite("Generated file imports")
struct GeneratedImportsTests {

    private func imports(_ dependencies: [String]) -> [String] {
        HeaderGenerator(dependencies: dependencies).render().filter { $0.hasPrefix("import ") }
    }

    @Test("event files import EventSourcing, not KurrentSupport")
    func eventImports() {
        #expect(imports(GeneratedImports.event) == ["import Foundation", "import DDDCore", "import EventSourcing"])
    }

    @Test("event mapper files import EventSourcing, not KurrentSupport or KurrentDB")
    func eventMapperImports() {
        #expect(imports(GeneratedImports.eventMapper) == ["import Foundation", "import DDDCore", "import EventSourcing"])
    }

    @Test("projection model files are unchanged")
    func projectionModelImports() {
        #expect(imports(GeneratedImports.projectionModel) == ["import Foundation", "import DDDCore", "import EventSourcing"])
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `swift test --filter GeneratedImportsTests`
Expected: compile error, `cannot find 'GeneratedImports' in scope`.

- [ ] **Step 3: Implement**

`Sources/DomainEventGenerator/Generator/Common/GeneratedImports.swift`:

```swift
//
//  GeneratedImports.swift
//  DDDKit
//

/// Modules every generated file imports before the config's own `dependencies`.
/// Generated code only uses DDDCore and EventSourcing types, so it compiles
/// against any `EventStore`, not only KurrentDB.
package enum GeneratedImports {
    package static let event = ["Foundation", "DDDCore", "EventSourcing"]
    package static let eventMapper = ["Foundation", "DDDCore", "EventSourcing"]
    package static let projectionModel = ["Foundation", "DDDCore", "EventSourcing"]
}
```

In `Sources/generate/Event.swift` replace
`let defaultDependencies = ["Foundation", "DDDCore", "KurrentSupport"]`
with `let defaultDependencies = GeneratedImports.event`.

In `Sources/generate/EventMapper.swift` replace
`let defaultDependencies = ["Foundation", "DDDCore", "KurrentSupport", "KurrentDB"]`
with `let defaultDependencies = GeneratedImports.eventMapper`.

In `Sources/generate/ProjectionModel.swift` replace
`let defaultDependencies = ["Foundation", "DDDCore", "EventSourcing"]`
with `let defaultDependencies = GeneratedImports.projectionModel`.

- [ ] **Step 4: Run the test and rebuild the plugin fixture**

Run: `swift test --filter GeneratedImportsTests`
Expected: 3 tests passed.

Run: `swift build --target ProjectorGeneratorFixture`
Expected: `Build complete!` (the plugin regenerates the fixture's files with the new imports and they compile).

- [ ] **Step 5: Commit**

```bash
git add Sources/DomainEventGenerator/Generator/Common/GeneratedImports.swift Sources/generate Tests/DomainEventGeneratorTests/GeneratedImportsTests.swift
git commit -m "feat(generator): import EventSourcing instead of KurrentSupport/KurrentDB in generated files

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Rename `InMemoryStorageCoordinator` → `InMemoryEventStore` (no behaviour change)

**Files:**
- Rename: `Sources/EventSourcing/EventStorageCoordinator/InMemoryStorageCoordinator.swift` → `InMemoryEventStore.swift`
- Modify: `Sources/ProjectorGeneratorFixture/OrderSummaryFixture.swift`, `Tests/ReadModelPersistenceTests/StatefulProjectorTests.swift`, `Tests/EventSourcingTests/EventSourcingRepositoryMetadataTests.swift`, `samples/StatefulReadModelDemo/Sources/main.swift`, `samples/PostgresReadModelDemo/Sources/main.swift`, `Sources/KurrentSupportInMemory/InMemoryEventStoreClient.swift` (comment only)

- [ ] **Step 1: Rename the file and the type**

```bash
git mv Sources/EventSourcing/EventStorageCoordinator/InMemoryStorageCoordinator.swift \
       Sources/EventSourcing/EventStorageCoordinator/InMemoryEventStore.swift
```

In that file change `public actor InMemoryStorageCoordinator<Metadata: EventMetadata>: EventStore {` to `public actor InMemoryEventStore<Metadata: EventMetadata>: EventStore {`. Leave the body as is (Task 6 changes behaviour).

Append the deprecated old name:

```swift
@available(*, deprecated, renamed: "InMemoryEventStore", message: "Renamed in 1.5 and now follows the EventStore contract: revisions start at 0, `version: nil` requires a new stream, conflicts throw DDDError.commitConflict. Removed in 1.6 at the earliest.")
public typealias InMemoryStorageCoordinator<Metadata: EventMetadata> = InMemoryEventStore<Metadata>
```

- [ ] **Step 2: Update in-repo usages**

```bash
sed -i '' 's/InMemoryStorageCoordinator</InMemoryEventStore</g' \
  Sources/ProjectorGeneratorFixture/OrderSummaryFixture.swift \
  Tests/ReadModelPersistenceTests/StatefulProjectorTests.swift \
  Tests/EventSourcingTests/EventSourcingRepositoryMetadataTests.swift \
  samples/StatefulReadModelDemo/Sources/main.swift \
  samples/PostgresReadModelDemo/Sources/main.swift
sed -i '' 's/InMemoryStorageCoordinator\.fetchEvents/InMemoryEventStore.fetchEvents/' Tests/ReadModelPersistenceTests/StatefulProjectorTests.swift
sed -i '' "s/Styled after \`EventSourcing\`'s \`InMemoryStorageCoordinator\`/Styled after \`EventSourcing\`'s \`InMemoryEventStore\`/" Sources/KurrentSupportInMemory/InMemoryEventStoreClient.swift
grep -rn "InMemoryStorageCoordinator" Sources Tests samples
```

Expected `grep` output: only the deprecated typealias and `InMemoryStorageCoordinatorError` in `InMemoryEventStore.swift`.

- [ ] **Step 3: Build and run the affected suites (old behaviour must still pass)**

Run: `swift build --build-tests && swift test --filter '(ReadModelPersistenceTests|EventSourcingTests|ProjectorGeneratorFixtureTests)'`
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add -A Sources Tests samples
git commit -m "refactor(event-sourcing): rename InMemoryStorageCoordinator to InMemoryEventStore

The old name stays as a deprecated typealias.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: `EventStoreContract` target and contract tests (red)

**Files:**
- Modify: `Package.swift` (two targets), `scripts/emit-symbol-graphs.sh:29`
- Create: `Sources/EventStoreContract/ContractFixtures.swift`, `Sources/EventStoreContract/EventStoreContract.swift`, `Tests/EventStoreContractTests/EventStoreContractTests.swift`

- [ ] **Step 1: Add the targets**

In `Package.swift`, after the `ReadModelPersistence` target add:

```swift
        // Internal (not a product): the EventStore contract as throwing check
        // functions, shared by every backend's tests. No `Testing` import.
        .target(
            name: "EventStoreContract",
            dependencies: [
                "DDDCore",
                "EventSourcing",
            ]),
        .testTarget(
            name: "EventStoreContractTests",
            dependencies: [
                "EventStoreContract",
                "EventSourcing",
                "DDDCore",
                "KurrentSupport",
                "KurrentSupportInMemory",
            ]),
```

In `scripts/emit-symbol-graphs.sh` line 29, add `EventStoreContract` to `EXCLUDED`:

```bash
EXCLUDED=" DDDKit generate DDDKitCLI TemplateVariablesDemo ProjectorGeneratorFixture EventStoreContract "
```

- [ ] **Step 2: Write the fixtures**

`Sources/EventStoreContract/ContractFixtures.swift`:

```swift
import DDDCore
import EventSourcing
import Foundation

/// Metadata every contract store is instantiated with.
public struct ContractMetadata: EventMetadata, Equatable {
    public let tag: String

    public init(tag: String) {
        self.tag = tag
    }
}

/// The event `ContractEventMapper` maps. `metadata` is filled on read from
/// `customMetadata`, the way the generated mappers do it.
public struct ContractEvent: DomainEvent {
    public typealias Metadata = ContractMetadata

    public var id: UUID
    public var occurred: Date
    public var aggregateRootId: String
    public var metadata: ContractMetadata?
    public var value: Int

    public init(id: UUID = UUID(), aggregateRootId: String, value: Int, occurred: Date = .now) {
        self.id = id
        self.occurred = occurred
        self.aggregateRootId = aggregateRootId
        self.metadata = nil
        self.value = value
    }
}

/// An event type `ContractEventMapper` does not know: the mapper returns `nil`.
public struct ContractUnmappedEvent: DomainEvent {
    public typealias Metadata = Never

    public var id: UUID
    public var occurred: Date
    public var aggregateRootId: String
    public var metadata: Never?

    public init(id: UUID = UUID(), aggregateRootId: String, occurred: Date = .now) {
        self.id = id
        self.occurred = occurred
        self.aggregateRootId = aggregateRootId
        self.metadata = nil
    }
}

/// An event type `ContractEventMapper` throws on.
public struct ContractUndecodableEvent: DomainEvent {
    public typealias Metadata = Never

    public var id: UUID
    public var occurred: Date
    public var aggregateRootId: String
    public var metadata: Never?

    public init(id: UUID = UUID(), aggregateRootId: String, occurred: Date = .now) {
        self.id = id
        self.occurred = occurred
        self.aggregateRootId = aggregateRootId
        self.metadata = nil
    }
}

/// Stream naming for stores that need one (`ContractStream-<id>`).
public enum ContractStream: EventStreamNaming {
    public static var categoryRule: StreamCategoryRule { .custom("ContractStream") }
    public static var category: String { "ContractStream" }
}

/// Maps `ContractEvent`, returns `nil` for unknown types, throws for
/// `ContractUndecodableEvent`.
public struct ContractEventMapper: EventTypeMapper {
    public struct UndecodableEvent: Error {}

    public init() {}

    public func mapping(eventData: any RecordedEventLike) throws -> (any DomainEvent)? {
        switch eventData.eventType {
        case "ContractEvent":
            guard var event = try eventData.decode(to: ContractEvent.self) else { return nil }
            event.metadata = eventData.customMetadata.isEmpty
                ? nil
                : try JSONDecoder().decode(ContractMetadata.self, from: eventData.customMetadata)
            return event
        case "ContractUndecodableEvent":
            throw UndecodableEvent()
        default:
            return nil
        }
    }
}
```

- [ ] **Step 3: Write the rules**

`Sources/EventStoreContract/EventStoreContract.swift`:

```swift
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
```

- [ ] **Step 4: Write the backend test**

`Tests/EventStoreContractTests/EventStoreContractTests.swift`:

```swift
import Testing
import EventSourcing
import EventStoreContract

@Suite("EventStore contract")
struct EventStoreContractTests {

    @Test("InMemoryEventStore")
    func inMemoryEventStore() async throws {
        try await EventStoreContract.checkAll(serialized: false) {
            InMemoryEventStore<ContractMetadata>()
        }
    }
}
```

- [ ] **Step 5: Run it and confirm it fails on the current behaviour**

Run: `swift test --filter EventStoreContractTests`
Expected: FAIL with `ContractViolation` `[3.1 empty append is a no-op] empty append on a new stream returned Optional(0)` (the old store appends empty batches and counts from 1).

- [ ] **Step 6: Commit the red tests**

```bash
git add Package.swift scripts/emit-symbol-graphs.sh Sources/EventStoreContract Tests/EventStoreContractTests
git commit -m "test(event-sourcing): add the EventStore contract as shared throwing checks

InMemoryEventStore does not pass yet.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: `InMemoryEventStore` follows the contract (green)

**Files:**
- Modify: `Sources/EventSourcing/EventStorageCoordinator/InMemoryEventStore.swift` (replace the actor)
- Modify: `Tests/ReadModelPersistenceTests/StatefulProjectorTests.swift`, `samples/StatefulReadModelDemo/Sources/main.swift`, `samples/PostgresReadModelDemo/Sources/main.swift`

- [ ] **Step 1: Replace the actor**

Replace everything above the deprecated typealias in `InMemoryEventStore.swift` with:

```swift
import DDDCore
import Foundation

/// A thread-safe, in-memory `EventStore` that follows the `EventStore` contract:
/// revisions start at 0, `version: nil` requires a new stream, a mismatch throws
/// `DDDError.commitConflict`, and `purge` makes an id permanently unwritable.
///
/// Events are kept as appended — no serialization, no mapper — so `fetchEvents`
/// does NOT populate `event.metadata`. Use `recordedMetadata(byId:)` to check
/// what `append` received.
public actor InMemoryEventStore<Metadata: EventMetadata>: EventStore {

    private struct Entry {
        var events: [any DomainEvent]
        var metadata: [Metadata?]   // 1:1 with events
    }

    private var store: [String: Entry] = [:]
    private var purged: Set<String> = []

    public init() {}

    public func fetchEvents(byId id: String) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)? {
        guard let entry = store[id] else { return nil }
        return (events: entry.events, latestRevision: UInt64(entry.events.count - 1))
    }

    public func fetchEvents(byId id: String, afterRevision revision: UInt64) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)? {
        guard let entry = store[id] else { return nil }
        let start = Int(revision) + 1
        guard start < entry.events.count else {
            return (events: [], latestRevision: revision)
        }
        return (events: Array(entry.events[start...]), latestRevision: UInt64(entry.events.count - 1))
    }

    public func append(
        events: [any DomainEvent],
        byId id: String,
        version: UInt64?,
        metadata: Metadata?
    ) async throws -> UInt64? {
        guard !events.isEmpty else { return nil }
        guard !purged.contains(id) else { throw DDDError.streamPurged(id: id) }

        var entry = store[id] ?? Entry(events: [], metadata: [])
        let tail: UInt64? = entry.events.isEmpty ? nil : UInt64(entry.events.count - 1)
        guard tail == version else {
            if let replayed = Self.idempotentRevision(of: events, in: entry.events, expected: version) {
                return replayed
            }
            throw DDDError.commitConflict(id: id, expected: version, actual: tail)
        }
        entry.events.append(contentsOf: events)
        entry.metadata.append(contentsOf: Array(repeating: metadata, count: events.count))
        store[id] = entry
        return UInt64(entry.events.count - 1)
    }

    public func purge(byId id: String) async throws {
        purged.insert(id)
        store.removeValue(forKey: id)
    }

    /// KurrentDB's id de-duplication: a batch whose ids equal the stored events
    /// right after `expected` was already written, so answer with its last revision.
    private static func idempotentRevision(
        of events: [any DomainEvent], in stored: [any DomainEvent], expected: UInt64?
    ) -> UInt64? {
        let start = expected.map { Int($0) + 1 } ?? 0
        let end = start + events.count
        guard end <= stored.count else { return nil }
        guard stored[start..<end].map({ $0.id }) == events.map({ $0.id }) else { return nil }
        return UInt64(end - 1)
    }

    // MARK: - Test inspection helpers

    /// Returns the metadata associated with each appended event (1:1, ordered).
    /// Test-only — production code should not depend on this.
    public func recordedMetadata(byId id: String) async -> [Metadata?] {
        store[id]?.metadata ?? []
    }
}

@available(*, deprecated, message: "No longer thrown. InMemoryEventStore throws DDDError.commitConflict.")
public enum InMemoryStorageCoordinatorError: Error {
    case versionConflict(expected: UInt64, actual: UInt64)
}
```

- [ ] **Step 2: Run the contract tests**

Run: `swift test --filter EventStoreContractTests`
Expected: PASS.

- [ ] **Step 3: Update tests that assumed 1-based revisions**

In `Tests/ReadModelPersistenceTests/StatefulProjectorTests.swift`:

- `firstExecuteFullReplayAndCaches`: `#expect(cached?.revision == 2)` → `#expect(cached?.revision == 1)`.
- `incrementalUpdateAppliesOnlyNewEvents`: the second append's `byId: "a1", version: 2, metadata: nil` → `byId: "a1", version: 1, metadata: nil`; `#expect(cached?.revision == 3)` → `#expect(cached?.revision == 2)`.
- `returnsEventsAfterRevision`: `afterRevision: 2` → `afterRevision: 1`; `#expect(result?.latestRevision == 3)` → `#expect(result?.latestRevision == 2)`.
- `returnsEmptyWhenUpToDate`: `afterRevision: 1` → `afterRevision: 0`; `#expect(result?.latestRevision == 1)` → `#expect(result?.latestRevision == 0)`.

Run: `swift test --filter '(ReadModelPersistenceTests|EventSourcingTests|ProjectorGeneratorFixtureTests|DDDKitUnitTests)'`
Expected: all pass.

- [ ] **Step 4: Fix the samples (each step appended with `version: nil`)**

In `samples/StatefulReadModelDemo/Sources/main.swift` replace the three appends with:

```swift
var revision = try await coordinator.append(
    events: [OrderCreated(orderId: orderId, customerId: "customer-42", totalAmount: 1000)],
    byId: orderId, version: nil, metadata: nil)
```

```swift
revision = try await coordinator.append(
    events: [OrderAmountUpdated(orderId: orderId, newAmount: 1500)],
    byId: orderId, version: revision, metadata: nil)
```

```swift
revision = try await coordinator.append(
    events: [OrderCancelled(aggregateRootId: orderId)],
    byId: orderId, version: revision, metadata: nil)
```

Make the same three replacements in `samples/PostgresReadModelDemo/Sources/main.swift` (indented by four spaces, inside the existing function).

Run: `swift build --package-path samples/StatefulReadModelDemo && swift run --package-path samples/StatefulReadModelDemo`
Expected: builds; prints three ReadModel states ending with `=== Done ===`.

Run: `swift build --package-path samples/PostgresReadModelDemo`
Expected: `Build complete!` (running it needs Postgres; not required here).

- [ ] **Step 5: Commit**

```bash
git add Sources/EventSourcing/EventStorageCoordinator/InMemoryEventStore.swift Tests/ReadModelPersistenceTests/StatefulProjectorTests.swift samples
git commit -m "feat(event-sourcing): InMemoryEventStore follows the EventStore contract

0-based revisions, nil requires a new stream, commitConflict on mismatch,
permanent purge, id-idempotent resend, empty append is a no-op.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: `EventStoreClient.tombstoneStream`

**Files:**
- Modify: `Sources/KurrentSupport/Adapter/EventStoreClient.swift` (protocol, default, error case), `Sources/KurrentSupport/Adapter/LiveEventStoreClient.swift`
- Test: `Tests/KurrentSupportUnitTests/TombstoneDefaultTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import KurrentDB
import KurrentSupport

/// A conformer written before 1.5: it has no `tombstoneStream`.
private struct LegacyClient: EventStoreClient {
    func append(events: [EventData], toStream name: String, category: String, expectedRevision: StreamRevision) async throws -> UInt64? { nil }
    func readStream(name: String, from revision: RevisionCursor, resolveLinks: Bool) async throws -> [any RecordedEventLike] { [] }
    func deleteStream(name: String, expectedRevision: StreamRevision) async throws {}
    func subscribePersistent(stream: String, group: String) async throws -> any PersistentSubscriptionSession {
        throw EventStoreClientError.subscriptionGroupNotFound(stream: stream, group: group)
    }
    func ensurePersistentSubscription(stream: String, group: String, settings: PersistentSubscriptionSettings) async throws {}
    func deletePersistentSubscription(stream: String, group: String) async throws {}
}

@Suite("EventStoreClient.tombstoneStream default")
struct TombstoneDefaultTests {
    @Test("a conformer without tombstoneStream still compiles and throws tombstoneUnsupported")
    func defaultThrows() async {
        await #expect(throws: EventStoreClientError.tombstoneUnsupported) {
            try await LegacyClient().tombstoneStream(name: "Order-1")
        }
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `swift test --filter TombstoneDefaultTests`
Expected: compile error, `value of type 'LegacyClient' has no member 'tombstoneStream'`.

- [ ] **Step 3: Implement**

In the `EventStoreClient` protocol, after `deleteStream`:

```swift
    /// Permanently deletes the stream (KurrentDB tombstone, expected revision `.any`).
    /// Afterwards reads, appends and deletes of `name` throw `KurrentError.resourceDeleted`;
    /// tombstoning it again throws the same. A stream that never existed is
    /// tombstoned too.
    func tombstoneStream(name: String) async throws
```

After the protocol:

```swift
extension EventStoreClient {
    /// Conformers written before 1.5 keep compiling; `KurrentStorageCoordinator.purge`
    /// through them fails at run time until they implement or forward this.
    public func tombstoneStream(name: String) async throws {
        throw EventStoreClientError.tombstoneUnsupported
    }
}
```

In `EventStoreClientError`, after `subscriptionGroupNotFound`:

```swift
    /// The conformance does not implement `tombstoneStream(name:)`. Wrappers around
    /// `LiveEventStoreClient` must forward it for `purge` to work.
    case tombstoneUnsupported
```

In `LiveEventStoreClient`, after `deleteStream`:

```swift
    public func tombstoneStream(name: String) async throws {
        _ = try await client.streams(specified: name).tombstone {
            $0.expectedRevision = .any
        }
    }
```

- [ ] **Step 4: Run it and confirm it passes**

Run: `swift test --filter TombstoneDefaultTests`
Expected: 1 test passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/KurrentSupport/Adapter/EventStoreClient.swift Sources/KurrentSupport/Adapter/LiveEventStoreClient.swift Tests/KurrentSupportUnitTests/TombstoneDefaultTests.swift
git commit -m "feat(kurrent): add EventStoreClient.tombstoneStream

Defaults to throwing tombstoneUnsupported so existing conformers compile.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: `InMemoryEventStoreClient` tombstone and id idempotency

**Files:**
- Modify: `Sources/KurrentSupportInMemory/InMemoryEventStoreClient.swift`
- Test: `Tests/KurrentSupportInMemoryTests/InMemoryEventStoreClientTombstoneTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
import KurrentDB
import KurrentSupport
import KurrentSupportInMemory

private struct SampleEvent: Codable, Sendable, Equatable {
    let text: String
}

private func sample(_ text: String) -> EventData {
    EventData(eventType: "SampleEvent", model: SampleEvent(text: text))
}

private func expectResourceDeleted(_ body: () async throws -> Void) async {
    let error = await #expect(throws: KurrentError.self) { try await body() }
    guard case .resourceDeleted = error else {
        Issue.record("expected resourceDeleted, got \(String(describing: error))")
        return
    }
}

@Suite("InMemoryEventStoreClient — tombstone and idempotency")
struct InMemoryEventStoreClientTombstoneTests {

    @Test("after tombstone, read, append, delete and tombstone throw resourceDeleted")
    func tombstoneIsPermanent() async throws {
        let client = InMemoryEventStoreClient()
        _ = try await client.append(events: [sample("a")], toStream: "Order-1", category: "Order", expectedRevision: .noStream)

        try await client.tombstoneStream(name: "Order-1")

        await expectResourceDeleted { _ = try await client.readStream(name: "Order-1", from: .start, resolveLinks: true) }
        await expectResourceDeleted { _ = try await client.append(events: [sample("b")], toStream: "Order-1", category: "Order", expectedRevision: .any) }
        await expectResourceDeleted { try await client.deleteStream(name: "Order-1", expectedRevision: .any) }
        await expectResourceDeleted { try await client.tombstoneStream(name: "Order-1") }
    }

    @Test("tombstoning a stream that never existed succeeds and blocks it")
    func tombstoneUnknownStream() async throws {
        let client = InMemoryEventStoreClient()
        try await client.tombstoneStream(name: "Order-9")
        await expectResourceDeleted { _ = try await client.append(events: [sample("a")], toStream: "Order-9", category: "Order", expectedRevision: .noStream) }
    }

    @Test("resending the same ids with .noStream returns the original revision without writing")
    func idempotentNoStream() async throws {
        let client = InMemoryEventStoreClient()
        let batch = [sample("a"), sample("b")]
        _ = try await client.append(events: batch, toStream: "Order-1", category: "Order", expectedRevision: .noStream)

        let resent = try await client.append(events: batch, toStream: "Order-1", category: "Order", expectedRevision: .noStream)

        #expect(resent == 1)
        let records = try await client.readStream(name: "Order-1", from: .start, resolveLinks: true)
        #expect(records.count == 2)
    }

    @Test("resending the same ids with .at(n) returns the original revision without writing")
    func idempotentAt() async throws {
        let client = InMemoryEventStoreClient()
        _ = try await client.append(events: [sample("a")], toStream: "Order-1", category: "Order", expectedRevision: .noStream)
        let next = [sample("b")]
        _ = try await client.append(events: next, toStream: "Order-1", category: "Order", expectedRevision: .at(0))

        let resent = try await client.append(events: next, toStream: "Order-1", category: "Order", expectedRevision: .at(0))

        #expect(resent == 1)
        let records = try await client.readStream(name: "Order-1", from: .start, resolveLinks: true)
        #expect(records.count == 2)
    }

    @Test("different ids at a stale revision still conflict")
    func differentIdsConflict() async throws {
        let client = InMemoryEventStoreClient()
        _ = try await client.append(events: [sample("a")], toStream: "Order-1", category: "Order", expectedRevision: .noStream)
        await #expect(throws: EventStoreClientError.wrongExpectedRevision(current: 0)) {
            _ = try await client.append(events: [sample("c")], toStream: "Order-1", category: "Order", expectedRevision: .noStream)
        }
    }
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `swift test --filter InMemoryEventStoreClientTombstoneTests`
Expected: `tombstoneIsPermanent` and `tombstoneUnknownStream` fail with `tombstoneUnsupported` (the protocol default); `idempotentNoStream`/`idempotentAt` fail with `wrongExpectedRevision`; `differentIdsConflict` passes.

- [ ] **Step 3: Implement**

Add a stored property next to `streams`:

```swift
    /// Names tombstoned via `tombstoneStream`. Like a real cluster, every later
    /// read/append/delete/tombstone of them throws `KurrentError.resourceDeleted`.
    private var tombstoned: Set<String> = []
```

At the top of `append` (before `let systemCategory`):

```swift
        if tombstoned.contains(name) { throw KurrentError.resourceDeleted(resource: name) }
```

In `append`, right after `let lastRevision = existing.last?.revision` and before `switch expectedRevision`:

```swift
        // KurrentDB de-duplicates by event id: resending a batch that is already
        // stored right after the expected position succeeds without writing.
        if let replayed = Self.idempotentRevision(of: events, in: existing, expected: expectedRevision) {
            return replayed
        }
```

At the top of `readStream` and of `deleteStream`:

```swift
        if tombstoned.contains(name) { throw KurrentError.resourceDeleted(resource: name) }
```

After `deleteStream`:

```swift
    public func tombstoneStream(name: String) async throws {
        guard !tombstoned.contains(name) else { throw KurrentError.resourceDeleted(resource: name) }
        tombstoned.insert(name)
        streams.removeValue(forKey: name)
    }
```

In the `// MARK: - Category / subscription routing` section add:

```swift
    /// Only `.noStream` and `.at(n)` are covered — the cases the EventStore
    /// contract uses.
    private static func idempotentRevision(
        of events: [EventData], in stored: [StoredEvent], expected: StreamRevision
    ) -> UInt64? {
        guard !events.isEmpty else { return nil }
        let start: Int
        switch expected {
        case .noStream: start = 0
        case let .at(revision): start = Int(revision) + 1
        case .any, .streamExists: return nil
        }
        let end = start + events.count
        guard end <= stored.count else { return nil }
        guard stored[start..<end].map({ $0.id }) == events.map({ $0.id }) else { return nil }
        return stored[end - 1].revision
    }
```

- [ ] **Step 4: Run the new and existing in-memory client tests**

Run: `swift test --filter KurrentSupportInMemoryTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/KurrentSupportInMemory/InMemoryEventStoreClient.swift Tests/KurrentSupportInMemoryTests/InMemoryEventStoreClientTombstoneTests.swift
git commit -m "feat(kurrent-in-memory): tombstone and id idempotency in InMemoryEventStoreClient

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: `KurrentStorageCoordinator` follows the contract

**Files:**
- Modify: `Sources/KurrentSupport/Adapter/KurrentStorageCoordinator.swift`
- Modify: `Tests/EventStoreContractTests/EventStoreContractTests.swift`

- [ ] **Step 1: Add the Kurrent backend to the contract test**

```swift
import Testing
import EventSourcing
import EventStoreContract
import KurrentSupport
import KurrentSupportInMemory

@Suite("EventStore contract")
struct EventStoreContractTests {

    @Test("InMemoryEventStore")
    func inMemoryEventStore() async throws {
        try await EventStoreContract.checkAll(serialized: false) {
            InMemoryEventStore<ContractMetadata>()
        }
    }

    @Test("KurrentStorageCoordinator over InMemoryEventStoreClient")
    func kurrentOverInMemoryClient() async throws {
        try await EventStoreContract.checkAll(serialized: true) {
            KurrentStorageCoordinator<ContractStream, ContractMetadata>(
                client: InMemoryEventStoreClient(),
                eventMapper: ContractEventMapper()
            )
        }
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `swift test --filter EventStoreContractTests`
Expected: `kurrentOverInMemoryClient` FAILS inside `checkEmptyAppendIsNoOp`: the coordinator forwards the empty batch with `version: 99` to the client, which throws `EventStoreClientError.wrongExpectedRevision(current: nil)`.

- [ ] **Step 3: Implement**

Replace `append`:

```swift
    public func append(
        events: [any DDDCore.DomainEvent],
        byId id: String,
        version: UInt64?,
        metadata: Metadata?
    ) async throws -> UInt64? {
        guard !events.isEmpty else { return nil }
        let streamName = StreamNaming.getStreamName(id: id)
        let encoder = JSONEncoder()
        let metadataBytes: Data? = try metadata.map { try encoder.encode($0) }
        let eventDataList = try events.map { event in
            try EventData(
                id: event.id,
                eventType: event.eventType,
                model: event,
                customMetadata: metadataBytes
            )
        }
        // A `nil` version means the aggregate has never been persisted —
        // expect `.noStream` so a concurrent/duplicate create collides
        // with the existing stream instead of silently succeeding under
        // `.any` (which skips the concurrency check altogether).
        let expectedRevision: StreamRevision = version.map { .at($0) } ?? .noStream
        do {
            return try await client.append(events: eventDataList, toStream: streamName, category: StreamNaming.category, expectedRevision: expectedRevision)
        } catch let error as KurrentError {
            switch error {
            case let .wrongExpectedVersion(_, current):
                let actual: UInt64? = switch current {
                    case .noStream: nil
                    case let .revision(revision): revision
                }
                throw DDDError.commitConflict(id: id, expected: version, actual: actual)
            case .resourceDeleted:
                throw DDDError.streamPurged(id: id)
            default:
                throw error
            }
        } catch EventStoreClientError.wrongExpectedRevision(let current) {
            throw DDDError.commitConflict(id: id, expected: version, actual: current)
        }
    }
```

In both `fetchEvents` overloads:

- Delete the `occurred` sort. In `fetchEvents(byId:)` replace

```swift
            let events = eventWrappers.map(\.event)
            let sortedEvents = events.sorted {
                $0.occurred < $1.occurred
            }

            return (events: sortedEvents, latestRevision: latestRevision)
```

with

```swift
            // Stream order is revision order; do not re-sort.
            return (events: eventWrappers.map(\.event), latestRevision: latestRevision)
```

and in `fetchEvents(byId:afterRevision:)` replace

```swift
            let sortedEvents = eventWrappers.map(\.event).sorted {
                $0.occurred < $1.occurred
            }

            return (events: sortedEvents, latestRevision: latestRevision)
```

with

```swift
            return (events: eventWrappers.map(\.event), latestRevision: latestRevision)
```

- In both overloads, the catch chain becomes:

```swift
        } catch EventStoreClientError.streamNotFound {
            logger.warning("Skip an error happened, stream not found: \(streamName)")
            return nil
        } catch KurrentError.resourceDeleted {
            // Tombstoned by `purge`.
            return nil
        } catch {
            logger.error("The error happened when fetching events: \(error)")
            throw error
        }
```

Replace `purge`:

```swift
    /// Tombstones the stream: the id can never be written again, even if it never
    /// existed. KurrentDB keeps the data until a scavenge.
    public func purge(byId id: String) async throws {
        let streamName = StreamNaming.getStreamName(id: id)
        do {
            try await client.tombstoneStream(name: streamName)
        } catch KurrentError.resourceDeleted {
            // Already purged.
        }
    }
```

- [ ] **Step 4: Run the contract and Kurrent unit suites**

Run: `swift test --filter '(EventStoreContractTests|KurrentSupportInMemoryTests|KurrentSupportUnitTests)'`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/KurrentSupport/Adapter/KurrentStorageCoordinator.swift Tests/EventStoreContractTests/EventStoreContractTests.swift
git commit -m "feat(kurrent): KurrentStorageCoordinator follows the EventStore contract

commitConflict/streamPurged from existing KurrentDB errors, no client call
for empty appends, stream order instead of occurred sort, purge tombstones.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: `EventSourcingRepository` — `save` early return, `purge` direct

**Files:**
- Modify: `Sources/EventSourcing/EventSourcingRepository.swift:51-80`
- Modify: `Tests/DDDKitUnitTests/EventSourcingRepositoryTests.swift`

- [ ] **Step 1: Change and add tests**

Replace the `purgeNonExistentThrows` test with:

```swift
    @Test("purge 不存在的 aggregate 不拋錯，直接交給 store")
    func purgeNonExistentGoesToStore() async throws {
        let coordinator = InMemoryCoordinator()
        let repo = ItemRepository(store: coordinator)
        try await repo.purge(byId: "ghost")
        #expect(coordinator.purgedIds == ["ghost"])
    }

    @Test("沒有未提交事件時 save 不呼叫 store")
    func saveWithoutEventsSkipsStore() async throws {
        let coordinator = InMemoryCoordinator()
        let repo = ItemRepository(store: coordinator)
        let item = try Item(id: "item-1", name: "apple")
        try await repo.save(aggregateRoot: item)
        #expect(coordinator.appendCallCount == 1)

        try await repo.save(aggregateRoot: item)

        #expect(coordinator.appendCallCount == 1)
    }
```

In the test's `InMemoryCoordinator`, record purges. Add the property:

```swift
    let _purgedIds: Mutex<[String]> = .init([])

    var purgedIds: [String] {
        _purgedIds.withLock { $0 }
    }
```

and change its `purge` to:

```swift
    func purge(byId id: String) async throws {
        _purgedIds.withLock { $0.append(id) }
        store.removeValue(forKey: id)
    }
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `swift test --filter EventSourcingRepositoryTests`
Expected: `purgeNonExistentGoesToStore` fails with `aggregateNotFound`; `saveWithoutEventsSkipsStore` fails with `appendCallCount == 2`.

- [ ] **Step 3: Implement**

In `save`, before `let metadata = …`:

```swift
        guard !aggregateRoot.events.isEmpty else { return }
```

Replace `purge`:

```swift
    /// 危険操作!! 完全移除，不可恢復。該 id 之後永遠無法再寫入，不論先前是否存在。
    public func purge(byId id: AggregateRootType.ID) async throws {
        try await store.purge(byId: id)
    }
```

- [ ] **Step 4: Run the suites that use the repository**

Run: `swift test --filter '(DDDKitUnitTests|EventSourcingTests|ReadModelPersistenceTests|EventStoreContractTests)'`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/EventSourcing/EventSourcingRepository.swift Tests/DDDKitUnitTests/EventSourcingRepositoryTests.swift
git commit -m "feat(event-sourcing): save skips the store with no events; purge goes straight to the store

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Raise the swift-kurrentdb floor to 2.6.0

swift-kurrentdb 2.6.0 (tag commit 97ba60d4) is the release with the read-after-tombstone fix: reading a tombstoned stream throws `KurrentError.resourceDeleted` from both the buffered `read()` and `read().lazy`. The error surfaces while iterating, not from `read()` itself, and Task 9's catch chain already wraps the iteration. 2.6.0 also renames `KurrentError.CurrentRevisionOption` to `CurrentRevisionState`, keeping the old name as a deprecated typealias. Task 9 only pattern-matches `.wrongExpectedVersion(...)` and never names that type, so no deprecation warning results. Plan C's `KurrentLiveContractTests` ("read after purge → nil") depends on this floor.

**Files:**
- Modify: `Package.swift` (swift-kurrentdb dependency line)

- [ ] **Step 1: Raise the floor**

Replace `.package(url: "https://github.com/gradyzhuo/swift-kurrentdb.git", from: "2.3.0"),` with:

```swift
        // 2.6.0: reading a tombstoned stream throws KurrentError.resourceDeleted,
        // which KurrentStorageCoordinator maps to "purged" (EventStore contract §3.5).
        .package(url: "https://github.com/gradyzhuo/swift-kurrentdb.git", from: "2.6.0"),
```

- [ ] **Step 2: Resolve and build**

Run: `swift package update swift-kurrentdb && swift build --build-tests`
Expected: resolves 2.6.0 or later; `Build complete!` with no new `CurrentRevisionOption` deprecation warnings.

- [ ] **Step 3: Commit**

```bash
git add Package.swift
git commit -m "build: require swift-kurrentdb 2.6.0, whose reads report tombstoned streams

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: CLAUDE.md and final verification

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update CLAUDE.md**

- In the Build & Test section, change `EventSourcingTests` uses an in-memory `InMemoryStorageCoordinator`" to `InMemoryEventStore`, and add: "`EventStoreContractTests` runs the shared `EventStore` contract (`EventStoreContract` target, internal, not a product) against every in-repo store — no KurrentDB needed."
- In the layer tree, add under `EventSourcing`: "also `RecordedEventLike`, `EventTypeMapper`, `CustomMetadata` (moved from KurrentSupport in 1.5; KurrentSupport keeps typealiases)".
- Under Key Protocols, add:

```markdown
**`EventStore` contract** (EventSourcing, spec `docs/superpowers/specs/2026-10-23-eventstore-contract-design.md`) — revisions start at 0; empty `append` is a no-op returning `nil`; `version: nil` requires no stream; mismatch throws `DDDError.commitConflict` (501, `error.commitConflict`); resending the same event ids returns the original revision; `purge` is permanent for any id (`append` then throws `streamPurged`, 502). Events come back in stream order. `InMemoryEventStore` (renamed from `InMemoryStorageCoordinator`) and `KurrentStorageCoordinator` follow it; `EventStoreContract.checkAll` checks a store against it.
```

- In the `EventStoreClient` paragraph, add: "`tombstoneStream(name:)` (1.5) has a default that throws `tombstoneUnsupported`; `KurrentStorageCoordinator.purge` uses it, so wrappers must forward it."

- [ ] **Step 2: Full in-memory verification**

Run:

```bash
swift build --build-tests
swift test --no-parallel --filter '(DDDKitUnitTests|EventSourcingTests|KurrentSupportInMemoryTests|KurrentSupportUnitTests|ReadModelPersistenceTests|DomainEventGeneratorTests|ProjectorGeneratorFixtureTests|EventStoreContractTests)'
```

Expected: all pass.

Run: `bash scripts/emit-symbol-graphs.sh` (if it needs arguments, use the invocation from `.github/workflows/documentation.yml`)
Expected: no "undocumented module" error for `EventStoreContract`.

- [ ] **Step 3: Commit and open the PR**

```bash
git add CLAUDE.md
git commit -m "docs: describe the EventStore contract in CLAUDE.md

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -u origin feat/eventstore-contract
gh pr create --title "EventStore contract (1.5, part A)" --body "Implements docs/superpowers/specs/2026-10-23-eventstore-contract-design.md.

- DDDError 501–504
- RecordedEventLike / EventTypeMapper / CustomMetadata moved to EventSourcing
- InMemoryEventStore (renamed) and KurrentStorageCoordinator follow the contract
- EventStoreContract checks + EventStoreContractTests
- EventStoreClient.tombstoneStream; purge tombstones

Live KurrentDB verification and the CI job come with part C.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

Stop after opening the PR. Do not merge.
