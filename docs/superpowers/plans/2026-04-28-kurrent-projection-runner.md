# KurrentProjection.PersistentSubscriptionRunner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement Phase 1 of the spec at `docs/superpowers/specs/2026-04-28-kurrent-projection-runner-design.md` — a `KurrentProjection.PersistentSubscriptionRunner` that abstracts the subscription event-loop / ack-nack / dispatch-to-stateful-projector boilerplate currently duplicated across application-layer projection handlers.

**Architecture:** Single file at `Sources/KurrentSupport/Adapter/KurrentProjection.swift`. A `caseless enum KurrentProjection` namespace nests `NackAction`, `RetryPolicy` (protocol), `MaxRetriesPolicy` (struct), `RunnerStopped` (error), and the `PersistentSubscriptionRunner` (final class). Internal `Registration` struct type-erases each registered projector to `(RecordedEvent) async throws -> Void`. `OSAllocatedUnfairLock` protects the registration list (iOS 16+/macOS 13+ — chosen over Swift `Mutex<T>` which requires iOS 18+). `run()` subscribes, loops `for try await`, dispatches via `withThrowingTaskGroup`, and acks/nacks via `RetryPolicy`.

**Tech Stack:** Swift 6, swift-kurrentdb 2.x, Swift Testing (`import Testing`), swift-log.

**Spec reference:** `docs/superpowers/specs/2026-04-28-kurrent-projection-runner-design.md`

---

## File Structure

| Path | Responsibility |
|---|---|
| `Sources/KurrentSupport/Adapter/KurrentProjection.swift` (new) | Namespace + all public types + Runner |
| `Tests/KurrentSupportUnitTests/KurrentProjectionRetryPolicyTests.swift` (new) | Pure unit tests for `MaxRetriesPolicy` |
| `Tests/KurrentSupportUnitTests/KurrentProjectionRunnerSetupTests.swift` (new) | Pure unit tests for runner construction + register chaining |
| `Tests/KurrentSupportIntegrationTests/KurrentProjectionRunnerIntegrationTests.swift` (new) | Full end-to-end tests with real KurrentDB |
| `Package.swift` (modify) | Add two new test targets |

Single source file — spec said "先單檔，超過 300 行再拆"; estimated ≈200 lines.

---

## Pre-Flight

- [ ] **Verify KurrentDB is reachable**

```bash
docker ps --format '{{.Names}} {{.Image}}' | grep -i kurrent || echo "KurrentDB NOT running"
```

If not running, the integration tests in this plan will not pass. Start KurrentDB via:

```bash
docker run --rm -d -p 2113:2113 \
  -e KURRENTDB_CLUSTER_SIZE=1 \
  -e KURRENTDB_RUN_PROJECTIONS=All \
  -e KURRENTDB_START_STANDARD_PROJECTIONS=true \
  -e KURRENTDB_INSECURE=true \
  -e KURRENTDB_ENABLE_ATOM_PUB_OVER_HTTP=true \
  docker.kurrent.io/kurrent-latest/kurrentdb:25.1
```

- [ ] **Verify build is green before starting**

```bash
swift build
```

Expected: build succeeds with no errors.

---

## Task 1: Add Test Targets to Package.swift

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Add `KurrentSupportUnitTests` and `KurrentSupportIntegrationTests` targets**

Edit `Package.swift`. Insert after the existing `ReadModelPersistencePostgresIntegrationTests` target (around line 109):

```swift
.testTarget(
    name: "KurrentSupportUnitTests",
    dependencies: [
        "KurrentSupport",
        "EventSourcing",
        "ReadModelPersistence",
        .product(name: "KurrentDB", package: "swift-kurrentdb"),
    ]),
.testTarget(
    name: "KurrentSupportIntegrationTests",
    dependencies: [
        "KurrentSupport",
        "EventSourcing",
        "ReadModelPersistence",
        "TestUtility",
        .product(name: "KurrentDB", package: "swift-kurrentdb"),
    ]),
```

- [ ] **Step 2: Create empty test files**

```bash
mkdir -p Tests/KurrentSupportUnitTests Tests/KurrentSupportIntegrationTests
```

Create `Tests/KurrentSupportUnitTests/Placeholder.swift`:

```swift
import Testing

@Suite("KurrentSupportUnitTests Placeholder")
struct KurrentSupportUnitTestsPlaceholder {
    @Test func placeholder() { #expect(Bool(true)) }
}
```

Create `Tests/KurrentSupportIntegrationTests/Placeholder.swift`:

```swift
import Testing

@Suite("KurrentSupportIntegrationTests Placeholder")
struct KurrentSupportIntegrationTestsPlaceholder {
    @Test func placeholder() { #expect(Bool(true)) }
}
```

- [ ] **Step 3: Verify the test targets resolve**

```bash
swift build --build-tests
```

Expected: builds successfully (no missing module errors).

- [ ] **Step 4: Verify tests can be discovered**

```bash
swift test --filter KurrentSupportUnitTests 2>&1 | tail -5
swift test --filter KurrentSupportIntegrationTests 2>&1 | tail -5
```

Expected: both run, both report 1 test passed.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Tests/KurrentSupportUnitTests Tests/KurrentSupportIntegrationTests
git commit -m "[ADD] test targets: KurrentSupportUnitTests + KurrentSupportIntegrationTests"
```

---

## Task 2: Create `KurrentProjection` namespace + `NackAction`

**Files:**
- Create: `Sources/KurrentSupport/Adapter/KurrentProjection.swift`
- Create: `Tests/KurrentSupportUnitTests/KurrentProjectionNackActionTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/KurrentSupportUnitTests/KurrentProjectionNackActionTests.swift`:

```swift
import Testing
import KurrentSupport

@Suite("KurrentProjection.NackAction")
struct KurrentProjectionNackActionTests {

    @Test("All four nack actions are defined")
    func allCasesExist() {
        let cases: [KurrentProjection.NackAction] = [.retry, .skip, .park, .stop]
        #expect(cases.count == 4)
    }

    @Test("NackAction is Sendable")
    func isSendable() {
        // Compile-time check — sending across actor boundary requires Sendable.
        let _: any Sendable = KurrentProjection.NackAction.retry
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter KurrentProjectionNackActionTests 2>&1 | tail -10
```

Expected: FAIL — `cannot find 'KurrentProjection' in scope`.

- [ ] **Step 3: Create the namespace + enum**

Create `Sources/KurrentSupport/Adapter/KurrentProjection.swift`:

```swift
//
//  KurrentProjection.swift
//  KurrentSupport
//
//  Phase 1 — Persistent Subscription Runner.
//  See spec: docs/superpowers/specs/2026-04-28-kurrent-projection-runner-design.md
//

import Foundation
import KurrentDB

public enum KurrentProjection {

    public enum NackAction: Sendable {
        case retry
        case skip
        case park
        case stop
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter KurrentProjectionNackActionTests 2>&1 | tail -10
```

Expected: PASS — both tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/KurrentSupport/Adapter/KurrentProjection.swift Tests/KurrentSupportUnitTests/KurrentProjectionNackActionTests.swift
git commit -m "[ADD] KurrentProjection namespace + NackAction enum"
```

---

## Task 3: Add `RunnerStopped` error

**Files:**
- Modify: `Sources/KurrentSupport/Adapter/KurrentProjection.swift`
- Create: `Tests/KurrentSupportUnitTests/KurrentProjectionRunnerStoppedTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/KurrentSupportUnitTests/KurrentProjectionRunnerStoppedTests.swift`:

```swift
import Testing
import KurrentSupport

@Suite("KurrentProjection.RunnerStopped")
struct KurrentProjectionRunnerStoppedTests {

    @Test("RunnerStopped carries a reason string")
    func carriesReason() {
        let error = KurrentProjection.RunnerStopped(reason: "test reason")
        #expect(error.reason == "test reason")
    }

    @Test("RunnerStopped conforms to Error")
    func conformsToError() {
        let error: any Error = KurrentProjection.RunnerStopped(reason: "x")
        #expect(error is KurrentProjection.RunnerStopped)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter KurrentProjectionRunnerStoppedTests 2>&1 | tail -10
```

Expected: FAIL — `cannot find 'RunnerStopped'`.

- [ ] **Step 3: Add the error type**

Edit `Sources/KurrentSupport/Adapter/KurrentProjection.swift`. Inside the `enum KurrentProjection` block, after `NackAction`:

```swift
    public struct RunnerStopped: Error, Sendable {
        public let reason: String

        public init(reason: String) {
            self.reason = reason
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter KurrentProjectionRunnerStoppedTests 2>&1 | tail -10
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/KurrentSupport/Adapter/KurrentProjection.swift Tests/KurrentSupportUnitTests/KurrentProjectionRunnerStoppedTests.swift
git commit -m "[ADD] KurrentProjection.RunnerStopped error"
```

---

## Task 4: Add `RetryPolicy` protocol + `MaxRetriesPolicy`

**Files:**
- Modify: `Sources/KurrentSupport/Adapter/KurrentProjection.swift`
- Create: `Tests/KurrentSupportUnitTests/KurrentProjectionRetryPolicyTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/KurrentSupportUnitTests/KurrentProjectionRetryPolicyTests.swift`:

```swift
import Testing
import KurrentSupport

@Suite("KurrentProjection.MaxRetriesPolicy")
struct KurrentProjectionRetryPolicyTests {

    private struct DummyError: Error {}

    @Test("Returns .retry when retryCount < max")
    func retriesWhenUnderLimit() {
        let policy = KurrentProjection.MaxRetriesPolicy(max: 5)
        let action = policy.decide(error: DummyError(), retryCount: 0)
        #expect(action == .retry)
    }

    @Test("Returns .retry when retryCount is one below max")
    func retriesAtMaxMinusOne() {
        let policy = KurrentProjection.MaxRetriesPolicy(max: 5)
        #expect(policy.decide(error: DummyError(), retryCount: 4) == .retry)
    }

    @Test("Returns .skip when retryCount equals max")
    func skipsAtMax() {
        let policy = KurrentProjection.MaxRetriesPolicy(max: 5)
        #expect(policy.decide(error: DummyError(), retryCount: 5) == .skip)
    }

    @Test("Returns .skip when retryCount exceeds max")
    func skipsAboveMax() {
        let policy = KurrentProjection.MaxRetriesPolicy(max: 5)
        #expect(policy.decide(error: DummyError(), retryCount: 100) == .skip)
    }

    @Test("Default max is 5")
    func defaultMaxIsFive() {
        let policy = KurrentProjection.MaxRetriesPolicy()
        #expect(policy.max == 5)
    }

    @Test("NackAction equality works for assertions")
    func nackActionIsEquatable() {
        // Sanity check — the .decide return value must be comparable.
        let a: KurrentProjection.NackAction = .retry
        let b: KurrentProjection.NackAction = .retry
        #expect(a == b)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter KurrentProjectionRetryPolicyTests 2>&1 | tail -10
```

Expected: FAIL — `cannot find 'MaxRetriesPolicy'` and `'NackAction'.==` not defined.

- [ ] **Step 3: Make `NackAction` Equatable, add `RetryPolicy` + `MaxRetriesPolicy`**

Edit `Sources/KurrentSupport/Adapter/KurrentProjection.swift`. Update `NackAction` to add `Equatable`:

```swift
    public enum NackAction: Sendable, Equatable {
        case retry
        case skip
        case park
        case stop
    }
```

Then after `RunnerStopped`, add:

```swift
    public protocol RetryPolicy: Sendable {
        func decide(error: any Error, retryCount: Int) -> NackAction
    }

    public struct MaxRetriesPolicy: RetryPolicy {
        public let max: Int

        public init(max: Int = 5) {
            self.max = max
        }

        public func decide(error: any Error, retryCount: Int) -> NackAction {
            retryCount >= max ? .skip : .retry
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter KurrentProjectionRetryPolicyTests 2>&1 | tail -10
```

Expected: PASS — all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/KurrentSupport/Adapter/KurrentProjection.swift Tests/KurrentSupportUnitTests/KurrentProjectionRetryPolicyTests.swift
git commit -m "[ADD] KurrentProjection.RetryPolicy + MaxRetriesPolicy"
```

---

## Task 5: Add `PersistentSubscriptionRunner` skeleton

This task only adds the class and its `init`. The two `register` overloads and `run()` come in later tasks.

**Files:**
- Modify: `Sources/KurrentSupport/Adapter/KurrentProjection.swift`
- Create: `Tests/KurrentSupportUnitTests/KurrentProjectionRunnerSetupTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/KurrentSupportUnitTests/KurrentProjectionRunnerSetupTests.swift`:

```swift
import Testing
import KurrentDB
import KurrentSupport

@Suite("KurrentProjection.PersistentSubscriptionRunner — setup")
struct KurrentProjectionRunnerSetupTests {

    @Test("Can construct runner with default retry policy and logger")
    func constructWithDefaults() {
        let client = KurrentDBClient(settings: .localhost())
        let runner = KurrentProjection.PersistentSubscriptionRunner(
            client: client,
            stream: "$ce-Test",
            groupName: "test-group"
        )
        // Smoke check — runner exists and is Sendable.
        let _: any Sendable = runner
    }

    @Test("Can construct runner with explicit retry policy")
    func constructWithExplicitPolicy() {
        let client = KurrentDBClient(settings: .localhost())
        let runner = KurrentProjection.PersistentSubscriptionRunner(
            client: client,
            stream: "$ce-Test",
            groupName: "test-group",
            retryPolicy: KurrentProjection.MaxRetriesPolicy(max: 3)
        )
        let _: any Sendable = runner
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter KurrentProjectionRunnerSetupTests 2>&1 | tail -10
```

Expected: FAIL — `cannot find 'PersistentSubscriptionRunner'`.

- [ ] **Step 3: Add the class skeleton**

Edit `Sources/KurrentSupport/Adapter/KurrentProjection.swift`. Add `import os` at the top (after `import KurrentDB`):

```swift
import Foundation
import KurrentDB
import Logging
import os
```

Inside the namespace, after `MaxRetriesPolicy`, add:

```swift
    public final class PersistentSubscriptionRunner: Sendable {

        private let client: KurrentDBClient
        private let stream: String
        private let groupName: String
        private let retryPolicy: any RetryPolicy
        private let logger: Logger

        // Registrations are appended via `register` (chainable, sync) and read by `run()`.
        // Convention: register before run. Lock is defensive, not for concurrent register/run.
        private let _registrations = OSAllocatedUnfairLock<[Registration]>(initialState: [])

        public init(
            client: KurrentDBClient,
            stream: String,
            groupName: String,
            retryPolicy: any RetryPolicy = MaxRetriesPolicy(max: 5),
            logger: Logger = Logger(label: "KurrentProjection.PersistentSubscriptionRunner")
        ) {
            self.client = client
            self.stream = stream
            self.groupName = groupName
            self.retryPolicy = retryPolicy
            self.logger = logger
        }
    }

    fileprivate struct Registration: Sendable {
        let dispatch: @Sendable (RecordedEvent) async throws -> Void
    }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter KurrentProjectionRunnerSetupTests 2>&1 | tail -10
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/KurrentSupport/Adapter/KurrentProjection.swift Tests/KurrentSupportUnitTests/KurrentProjectionRunnerSetupTests.swift
git commit -m "[ADD] PersistentSubscriptionRunner skeleton with init"
```

---

## Task 6: Implement `register` (low-level overload)

Adds the closure-based escape hatch first because it's simpler and the high-level overload (Task 7) is built on top.

**Files:**
- Modify: `Sources/KurrentSupport/Adapter/KurrentProjection.swift`
- Modify: `Tests/KurrentSupportUnitTests/KurrentProjectionRunnerSetupTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/KurrentSupportUnitTests/KurrentProjectionRunnerSetupTests.swift`, inside the `@Suite` struct:

```swift
    @Test("register low-level overload is chainable and counts registrations")
    func lowLevelRegisterChains() {
        let client = KurrentDBClient(settings: .localhost())
        let runner = KurrentProjection.PersistentSubscriptionRunner(
            client: client,
            stream: "$ce-Test",
            groupName: "test-group"
        )
        let returned = runner
            .register(extractInput: { _ -> Int? in 1 }, execute: { _ in })
            .register(extractInput: { _ -> String? in nil }, execute: { _ in })

        #expect(returned === runner) // Same instance
        #expect(runner.registrationCount == 2)
    }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter KurrentProjectionRunnerSetupTests/lowLevelRegisterChains 2>&1 | tail -10
```

Expected: FAIL — `register` and `registrationCount` not defined.

- [ ] **Step 3: Implement low-level register + test-only `registrationCount`**

Edit `Sources/KurrentSupport/Adapter/KurrentProjection.swift`. Add to the `PersistentSubscriptionRunner` class body:

```swift
        @discardableResult
        public func register<Input: Sendable>(
            extractInput: @Sendable @escaping (RecordedEvent) -> Input?,
            execute: @Sendable @escaping (Input) async throws -> Void
        ) -> Self {
            let registration = Registration { record in
                guard let input = extractInput(record) else { return }
                try await execute(input)
            }
            _registrations.withLock { $0.append(registration) }
            return self
        }

        // Test-only — exposed for unit tests to verify register chaining.
        // Not for production use; the registration count has no public meaning.
        internal var registrationCount: Int {
            _registrations.withLock { $0.count }
        }
```

- [ ] **Step 4: Run test to verify it passes**

The `internal` `registrationCount` requires the test target to use `@testable import`. Update the import at the top of `Tests/KurrentSupportUnitTests/KurrentProjectionRunnerSetupTests.swift`:

```swift
import Testing
import KurrentDB
@testable import KurrentSupport
```

Then run:

```bash
swift test --filter KurrentProjectionRunnerSetupTests 2>&1 | tail -10
```

Expected: PASS — all three tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/KurrentSupport/Adapter/KurrentProjection.swift Tests/KurrentSupportUnitTests/KurrentProjectionRunnerSetupTests.swift
git commit -m "[ADD] PersistentSubscriptionRunner.register (low-level closure overload)"
```

---

## Task 7: Implement `register` (high-level overload for `StatefulEventSourcingProjector`)

**Files:**
- Modify: `Sources/KurrentSupport/Adapter/KurrentProjection.swift`
- Modify: `Tests/KurrentSupportUnitTests/KurrentProjectionRunnerSetupTests.swift`

- [ ] **Step 1: Write the failing test**

The test needs a tiny stub `EventSourcingProjector` and `ReadModelStore` to construct a `StatefulEventSourcingProjector`. Append to `Tests/KurrentSupportUnitTests/KurrentProjectionRunnerSetupTests.swift`:

```swift
import EventSourcing
import ReadModelPersistence
import DDDCore
import Foundation

private struct StubReadModel: ReadModel, Sendable {
    typealias ID = String
    let id: String
}

private struct StubInput: CQRSProjectorInput, Sendable {
    let id: String
}

// Minimal in-memory coordinator for tests — never actually called by registration.
private final class StubCoordinator: EventStorageCoordinator, @unchecked Sendable {
    func fetchEvents(byId id: String) async throws -> (events: [any DomainEvent], latestRevision: UInt64)? { nil }
    func fetchEvents(byId id: String, afterRevision revision: UInt64) async throws -> (events: [any DomainEvent], latestRevision: UInt64)? { nil }
    func append(events: [any DomainEvent], byId id: String, version: UInt64?, external: [String : String]?) async throws -> UInt64? { nil }
    func purge(byId id: String) async throws {}
}

private struct StubProjector: EventSourcingProjector {
    typealias Input = StubInput
    typealias ReadModelType = StubReadModel
    typealias StorageCoordinator = StubCoordinator

    let coordinator: StubCoordinator

    func apply(readModel: inout StubReadModel, events: [any DomainEvent]) throws {}
    func buildReadModel(input: StubInput) throws -> StubReadModel? { StubReadModel(id: input.id) }
}

extension KurrentProjectionRunnerSetupTests {

    @Test("register high-level overload (StatefulEventSourcingProjector) is chainable")
    func highLevelRegisterChains() async {
        let client = KurrentDBClient(settings: .localhost())
        let store = await InMemoryReadModelStore<StubReadModel>()
        let projector = StubProjector(coordinator: StubCoordinator())
        let stateful = StatefulEventSourcingProjector(projector: projector, store: store)

        let runner = KurrentProjection.PersistentSubscriptionRunner(
            client: client,
            stream: "$ce-Stub",
            groupName: "stub-group"
        )

        let returned = runner.register(stateful) { _ in StubInput(id: "x") }

        #expect(returned === runner)
        #expect(runner.registrationCount == 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter KurrentProjectionRunnerSetupTests/highLevelRegisterChains 2>&1 | tail -15
```

Expected: FAIL — `register(_:extractInput:)` overload not found.

- [ ] **Step 3: Implement high-level register**

Edit `Sources/KurrentSupport/Adapter/KurrentProjection.swift`. Add `import EventSourcing` and `import ReadModelPersistence` at the top:

```swift
import Foundation
import KurrentDB
import Logging
import os
import EventSourcing
import ReadModelPersistence
```

Add to the `PersistentSubscriptionRunner` class body, before the low-level `register`:

```swift
        /// Register a `StatefulEventSourcingProjector`. The `extractInput` closure
        /// is called for each incoming event; return `nil` to skip this projector.
        ///
        /// - Important: The projector's `execute` must be idempotent. The runner
        ///   nacks the entire event on any failure, which causes the event to be
        ///   re-delivered. Already-successful projectors will be invoked again on
        ///   re-delivery; `StatefulEventSourcingProjector` handles this naturally
        ///   via its stored revision cursor (subsequent invocations become no-ops).
        @discardableResult
        public func register<Projector: EventSourcingProjector, Store: ReadModelStore>(
            _ stateful: StatefulEventSourcingProjector<Projector, Store>,
            extractInput: @Sendable @escaping (RecordedEvent) -> Projector.Input?
        ) -> Self
            where Store.Model == Projector.ReadModelType,
                  Projector.Input: Sendable
        {
            return register(extractInput: extractInput) { input in
                _ = try await stateful.execute(input: input)
            }
        }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter KurrentProjectionRunnerSetupTests 2>&1 | tail -10
```

Expected: PASS — all four tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/KurrentSupport/Adapter/KurrentProjection.swift Tests/KurrentSupportUnitTests/KurrentProjectionRunnerSetupTests.swift
git commit -m "[ADD] PersistentSubscriptionRunner.register (StatefulEventSourcingProjector overload)"
```

---

## Task 8: Implement `dispatch(record:)` — internal parallel TaskGroup

This task adds the dispatch logic as an internal method so it's testable. The full `run()` loop comes in Task 9.

**Files:**
- Modify: `Sources/KurrentSupport/Adapter/KurrentProjection.swift`

- [ ] **Step 1: Add dispatch method (no test in this task)**

Edit `Sources/KurrentSupport/Adapter/KurrentProjection.swift`. Add to the `PersistentSubscriptionRunner` class body, after the register methods:

```swift
        /// Dispatch a single recorded event to all registered projectors in parallel.
        /// Throws if any projector throws (TaskGroup semantics — others are cancelled).
        internal func dispatch(record: RecordedEvent) async throws {
            let snapshot = _registrations.withLock { $0 }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for registration in snapshot {
                    group.addTask {
                        try await registration.dispatch(record)
                    }
                }
                try await group.waitForAll()
            }
        }
```

- [ ] **Step 2: Verify build still succeeds**

```bash
swift build 2>&1 | tail -10
```

Expected: build succeeds. (No new test — `dispatch` requires a real `RecordedEvent` which can only be constructed by the swift-kurrentdb package; unit testing is impossible. This logic is covered by the integration tests in Tasks 11–14.)

- [ ] **Step 3: Commit**

```bash
git add Sources/KurrentSupport/Adapter/KurrentProjection.swift
git commit -m "[ADD] PersistentSubscriptionRunner.dispatch — parallel TaskGroup"
```

---

## Task 9: Implement `run()` — subscribe + ack-only happy path

This task wires up the subscription event loop. Failure handling (nack) comes in Task 10. We test the happy path now via integration test.

**Files:**
- Modify: `Sources/KurrentSupport/Adapter/KurrentProjection.swift`
- Create: `Tests/KurrentSupportIntegrationTests/KurrentProjectionRunnerIntegrationTests.swift`

- [ ] **Step 1: Write the failing integration test**

Create `Tests/KurrentSupportIntegrationTests/KurrentProjectionRunnerIntegrationTests.swift`:

```swift
import Testing
import Foundation
import KurrentDB
import KurrentSupport
import TestUtility
import Logging

@Suite("KurrentProjection.PersistentSubscriptionRunner — happy path", .serialized)
struct KurrentProjectionRunnerHappyPathTests {

    private static func makeClient() -> KurrentDBClient {
        KurrentDBClient(
            settings: .localhost().authenticated(.credentials(username: "admin", password: "changeit"))
        )
    }

    @Test("Runner dispatches event to all registered projectors and acks")
    func dispatchesAndAcks() async throws {
        let client = Self.makeClient()
        let groupName = "test-runner-happy-\(UUID().uuidString.prefix(8))"
        let category = "RunnerHappyTest\(UUID().uuidString.prefix(6))"
        let stream = "$ce-\(category)"

        // Set up a persistent subscription and append one event.
        try await client.persistentSubscriptions(stream: stream, group: groupName).create()
        defer {
            // Best-effort cleanup.
            Task { try? await client.persistentSubscriptions(stream: stream, group: groupName).delete() }
        }

        let aggregateId = UUID().uuidString
        let aggregateStream = "\(category)-\(aggregateId)"
        let payload = #"{"hello":"world"}"#.data(using: .utf8)!
        let eventData = try EventData(eventType: "TestEvent", payload: payload)
        _ = try await client.streams(of: .specified(stream: aggregateStream)).append(events: eventData) { _ in }

        // Capture which inputs each registered closure received.
        let captured = LockedBox<[String]>([])
        let runner = KurrentProjection.PersistentSubscriptionRunner(
            client: client,
            stream: stream,
            groupName: groupName
        )
        .register(extractInput: { record -> String? in
            record.streamIdentifier.name
        }, execute: { (streamName: String) in
            captured.withLock { $0.append(streamName) }
        })

        // Run the runner in a background task; cancel after a short window.
        let task = Task { try await runner.run() }
        try await Task.sleep(for: .seconds(2))
        task.cancel()
        _ = try? await task.value

        let names = captured.withLock { $0 }
        #expect(names.contains(aggregateStream))
    }
}

// Tiny helper for thread-safe shared state in tests.
final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ initial: Value) { value = initial }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter KurrentProjectionRunnerHappyPathTests 2>&1 | tail -20
```

Expected: FAIL — `run()` not defined.

- [ ] **Step 3: Implement `run()` (happy path only)**

Edit `Sources/KurrentSupport/Adapter/KurrentProjection.swift`. Add to the `PersistentSubscriptionRunner` class body:

```swift
        /// Subscribe to the persistent subscription and dispatch each event to all
        /// registered projectors in parallel. Acks on success.
        ///
        /// Returns when the parent `Task` is cancelled. Throws on subscription
        /// connection failure (no auto-reconnect — caller must restart via
        /// ServiceGroup or similar).
        public func run() async throws {
            let subscription = try await client
                .persistentSubscriptions(stream: stream, group: groupName)
                .subscribe()

            for try await result in subscription.events {
                if Task.isCancelled { return }

                let record = result.event.record
                do {
                    try await dispatch(record: record)
                    try await subscription.ack(readEvents: result.event)
                } catch {
                    // Failure handling (nack via RetryPolicy) — implemented in Task 10.
                    logger.error("dispatch failed for event \(record.id) (type: \(record.eventType)): \(error). Failure handling not yet implemented; event will be re-delivered by KurrentDB.")
                }
            }
        }
```

- [ ] **Step 4: Run test to verify it passes**

Ensure KurrentDB is running (see Pre-Flight). Then:

```bash
swift test --filter KurrentProjectionRunnerHappyPathTests 2>&1 | tail -20
```

Expected: PASS — `dispatchesAndAcks` passes; the captured array contains the aggregate stream name.

- [ ] **Step 5: Commit**

```bash
git add Sources/KurrentSupport/Adapter/KurrentProjection.swift Tests/KurrentSupportIntegrationTests/KurrentProjectionRunnerIntegrationTests.swift
git commit -m "[ADD] PersistentSubscriptionRunner.run — subscribe + ack happy path"
```

---

## Task 10: Implement failure handling — `RetryPolicy` + `nack`

**Files:**
- Modify: `Sources/KurrentSupport/Adapter/KurrentProjection.swift`
- Modify: `Tests/KurrentSupportIntegrationTests/KurrentProjectionRunnerIntegrationTests.swift`

- [ ] **Step 1: Write the failing integration test**

Append to `Tests/KurrentSupportIntegrationTests/KurrentProjectionRunnerIntegrationTests.swift`:

```swift
@Suite("KurrentProjection.PersistentSubscriptionRunner — failure handling", .serialized)
struct KurrentProjectionRunnerFailureTests {

    private static func makeClient() -> KurrentDBClient {
        KurrentDBClient(
            settings: .localhost().authenticated(.credentials(username: "admin", password: "changeit"))
        )
    }

    private struct FailFirstNTimes: KurrentProjection.RetryPolicy, Sendable {
        // Test policy — surfaces the retry decision via NackAction.
        // Use MaxRetriesPolicy with a low max so retries become .skip quickly.
        func decide(error: any Error, retryCount: Int) -> KurrentProjection.NackAction {
            retryCount >= 2 ? .skip : .retry
        }
    }

    @Test("Failing projector triggers nack(.retry) until policy returns .skip")
    func failingProjectorRetriesAndSkips() async throws {
        let client = Self.makeClient()
        let groupName = "test-runner-fail-\(UUID().uuidString.prefix(8))"
        let category = "RunnerFailTest\(UUID().uuidString.prefix(6))"
        let stream = "$ce-\(category)"

        try await client.persistentSubscriptions(stream: stream, group: groupName).create()
        defer { Task { try? await client.persistentSubscriptions(stream: stream, group: groupName).delete() } }

        let aggregateStream = "\(category)-\(UUID().uuidString)"
        let payload = #"{}"#.data(using: .utf8)!
        let eventData = try EventData(eventType: "TestEvent", payload: payload)
        _ = try await client.streams(of: .specified(stream: aggregateStream)).append(events: eventData) { _ in }

        struct AlwaysFails: Error {}

        let callCount = LockedBox(0)
        let runner = KurrentProjection.PersistentSubscriptionRunner(
            client: client,
            stream: stream,
            groupName: groupName,
            retryPolicy: FailFirstNTimes()
        )
        .register(extractInput: { _ -> Bool? in true }, execute: { _ in
            callCount.withLock { $0 += 1 }
            throw AlwaysFails()
        })

        let task = Task { try await runner.run() }
        try await Task.sleep(for: .seconds(4))
        task.cancel()
        _ = try? await task.value

        // Expect at least 3 invocations: initial + 2 retries before skip.
        let count = callCount.withLock { $0 }
        #expect(count >= 3, "Expected at least 3 calls (initial + 2 retries), got \(count)")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter KurrentProjectionRunnerFailureTests 2>&1 | tail -20
```

Expected: FAIL — failing dispatch is logged but not re-driven; `count` will be 1 (initial only — KurrentDB doesn't re-deliver without a nack).

- [ ] **Step 3: Replace the placeholder logger.error with proper failure handling**

Edit `Sources/KurrentSupport/Adapter/KurrentProjection.swift`. Replace the `catch` block in `run()` with a call to a new private method:

```swift
        public func run() async throws {
            let subscription = try await client
                .persistentSubscriptions(stream: stream, group: groupName)
                .subscribe()

            for try await result in subscription.events {
                if Task.isCancelled { return }

                let record = result.event.record
                do {
                    try await dispatch(record: record)
                    try await subscription.ack(readEvents: result.event)
                } catch {
                    try await handleFailure(
                        error: error,
                        result: result,
                        subscription: subscription
                    )
                }
            }
        }

        private func handleFailure(
            error: any Error,
            result: PersistentSubscription.EventResult,
            subscription: PersistentSubscriptions<SpecifiedPersistentSubscriptionTarget>.Subscription
        ) async throws {
            let action = retryPolicy.decide(error: error, retryCount: Int(result.retryCount))
            let kurrentAction: PersistentSubscriptions.Nack.Action = switch action {
                case .retry: .retry
                case .skip:  .skip
                case .park:  .park
                case .stop:  .stop
            }
            do {
                try await subscription.nack(
                    readEvents: [result.event],
                    action: kurrentAction,
                    reason: "\(error)"
                )
            } catch let nackError {
                logger.error("nack failed for event \(result.event.record.id): \(nackError)")
                // Continue — nack failure should not crash the run loop.
            }

            if case .stop = action {
                throw RunnerStopped(reason: "RetryPolicy returned .stop after \(result.retryCount) retries: \(error)")
            }
        }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter KurrentProjectionRunnerFailureTests 2>&1 | tail -20
```

Expected: PASS — `count >= 3`.

- [ ] **Step 5: Commit**

```bash
git add Sources/KurrentSupport/Adapter/KurrentProjection.swift Tests/KurrentSupportIntegrationTests/KurrentProjectionRunnerIntegrationTests.swift
git commit -m "[ADD] PersistentSubscriptionRunner failure handling — RetryPolicy + nack"
```

---

## Task 11: `.stop` action throws `RunnerStopped`

**Files:**
- Modify: `Tests/KurrentSupportIntegrationTests/KurrentProjectionRunnerIntegrationTests.swift`

The implementation is already in place from Task 10. This task is the integration test that proves it.

- [ ] **Step 1: Write the failing test**

Append to `Tests/KurrentSupportIntegrationTests/KurrentProjectionRunnerIntegrationTests.swift`:

```swift
@Suite("KurrentProjection.PersistentSubscriptionRunner — .stop semantics", .serialized)
struct KurrentProjectionRunnerStopTests {

    private static func makeClient() -> KurrentDBClient {
        KurrentDBClient(
            settings: .localhost().authenticated(.credentials(username: "admin", password: "changeit"))
        )
    }

    private struct StopImmediatelyPolicy: KurrentProjection.RetryPolicy, Sendable {
        func decide(error: any Error, retryCount: Int) -> KurrentProjection.NackAction { .stop }
    }

    @Test("RetryPolicy returning .stop causes run() to throw RunnerStopped")
    func stopThrowsRunnerStopped() async throws {
        let client = Self.makeClient()
        let groupName = "test-runner-stop-\(UUID().uuidString.prefix(8))"
        let category = "RunnerStopTest\(UUID().uuidString.prefix(6))"
        let stream = "$ce-\(category)"

        try await client.persistentSubscriptions(stream: stream, group: groupName).create()
        defer { Task { try? await client.persistentSubscriptions(stream: stream, group: groupName).delete() } }

        let aggregateStream = "\(category)-\(UUID().uuidString)"
        let payload = #"{}"#.data(using: .utf8)!
        let eventData = try EventData(eventType: "TestEvent", payload: payload)
        _ = try await client.streams(of: .specified(stream: aggregateStream)).append(events: eventData) { _ in }

        struct AlwaysFails: Error {}

        let runner = KurrentProjection.PersistentSubscriptionRunner(
            client: client,
            stream: stream,
            groupName: groupName,
            retryPolicy: StopImmediatelyPolicy()
        )
        .register(extractInput: { _ -> Bool? in true }, execute: { _ in throw AlwaysFails() })

        await #expect(throws: KurrentProjection.RunnerStopped.self) {
            try await runner.run()
        }
    }
}
```

- [ ] **Step 2: Run test to verify it passes**

(The implementation from Task 10 already throws `RunnerStopped` for `.stop`. This test verifies that.)

```bash
swift test --filter KurrentProjectionRunnerStopTests 2>&1 | tail -15
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/KurrentSupportIntegrationTests/KurrentProjectionRunnerIntegrationTests.swift
git commit -m "[ADD] integration test: .stop action throws RunnerStopped"
```

---

## Task 12: Cancellation returns normally (no `CancellationError`)

**Files:**
- Modify: `Tests/KurrentSupportIntegrationTests/KurrentProjectionRunnerIntegrationTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/KurrentSupportIntegrationTests/KurrentProjectionRunnerIntegrationTests.swift`:

```swift
@Suite("KurrentProjection.PersistentSubscriptionRunner — cancellation", .serialized)
struct KurrentProjectionRunnerCancellationTests {

    private static func makeClient() -> KurrentDBClient {
        KurrentDBClient(
            settings: .localhost().authenticated(.credentials(username: "admin", password: "changeit"))
        )
    }

    @Test("External Task.cancel() returns normally without throwing")
    func cancelReturnsNormally() async throws {
        let client = Self.makeClient()
        let groupName = "test-runner-cancel-\(UUID().uuidString.prefix(8))"
        let category = "RunnerCancelTest\(UUID().uuidString.prefix(6))"
        let stream = "$ce-\(category)"

        try await client.persistentSubscriptions(stream: stream, group: groupName).create()
        defer { Task { try? await client.persistentSubscriptions(stream: stream, group: groupName).delete() } }

        let runner = KurrentProjection.PersistentSubscriptionRunner(
            client: client,
            stream: stream,
            groupName: groupName
        )

        let task = Task { try await runner.run() }
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()

        // run() should complete without throwing.
        // .value will rethrow if the task threw.
        _ = try await task.value
    }
}
```

- [ ] **Step 2: Run the test**

```bash
swift test --filter KurrentProjectionRunnerCancellationTests 2>&1 | tail -15
```

Expected: PASS — the implementation already handles cancellation by checking `Task.isCancelled` at the top of each loop iteration. If this fails (e.g., the for-await throws `CancellationError`), proceed to Step 3; otherwise skip to Step 4.

- [ ] **Step 3: Fix cancellation handling if test failed**

If the test throws `CancellationError`, edit `Sources/KurrentSupport/Adapter/KurrentProjection.swift`. Wrap the for-await:

```swift
        public func run() async throws {
            let subscription = try await client
                .persistentSubscriptions(stream: stream, group: groupName)
                .subscribe()

            do {
                for try await result in subscription.events {
                    if Task.isCancelled { return }
                    let record = result.event.record
                    do {
                        try await dispatch(record: record)
                        try await subscription.ack(readEvents: result.event)
                    } catch {
                        try await handleFailure(error: error, result: result, subscription: subscription)
                    }
                }
            } catch is CancellationError {
                return
            }
        }
```

Re-run the test:

```bash
swift test --filter KurrentProjectionRunnerCancellationTests 2>&1 | tail -10
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Tests/KurrentSupportIntegrationTests/KurrentProjectionRunnerIntegrationTests.swift Sources/KurrentSupport/Adapter/KurrentProjection.swift
git commit -m "[ADD] integration test: cancellation returns normally"
```

---

## Task 13: Subscription connection failure throws out of `run()`

**Files:**
- Modify: `Tests/KurrentSupportIntegrationTests/KurrentProjectionRunnerIntegrationTests.swift`

The implementation is already in place — `subscribe()` and `for try await` propagate `KurrentError`. This task verifies it.

- [ ] **Step 1: Write the failing test**

Append to `Tests/KurrentSupportIntegrationTests/KurrentProjectionRunnerIntegrationTests.swift`:

```swift
@Suite("KurrentProjection.PersistentSubscriptionRunner — subscription failure", .serialized)
struct KurrentProjectionRunnerSubscriptionFailureTests {

    private static func makeClient() -> KurrentDBClient {
        KurrentDBClient(
            settings: .localhost().authenticated(.credentials(username: "admin", password: "changeit"))
        )
    }

    @Test("subscribe() failure (group does not exist) throws out of run()")
    func subscribeFailureThrows() async throws {
        let client = Self.makeClient()
        let nonExistentGroup = "definitely-not-a-real-group-\(UUID().uuidString)"
        let stream = "$ce-NoSuchCategory\(UUID().uuidString.prefix(6))"

        let runner = KurrentProjection.PersistentSubscriptionRunner(
            client: client,
            stream: stream,
            groupName: nonExistentGroup
        )

        // Calling run() without first creating the persistent subscription should throw.
        await #expect(throws: (any Error).self) {
            try await runner.run()
        }
    }
}
```

- [ ] **Step 2: Run the test**

```bash
swift test --filter KurrentProjectionRunnerSubscriptionFailureTests 2>&1 | tail -15
```

Expected: PASS — `KurrentError` propagates out.

- [ ] **Step 3: Commit**

```bash
git add Tests/KurrentSupportIntegrationTests/KurrentProjectionRunnerIntegrationTests.swift
git commit -m "[ADD] integration test: subscription failure throws out of run()"
```

---

## Task 14: Polish — doc comments + remove test-only `registrationCount`

The internal `registrationCount` was added in Task 6 to support unit tests. Decide whether to keep it (testing aid) or remove it (smaller surface). This task keeps it but marks it clearly. Also adds top-level doc comments.

**Files:**
- Modify: `Sources/KurrentSupport/Adapter/KurrentProjection.swift`

- [ ] **Step 1: Add a top-level doc comment to the namespace**

Edit `Sources/KurrentSupport/Adapter/KurrentProjection.swift`. Replace the namespace declaration:

```swift
/// Phase 1 of the KurrentDB read-side projection runner.
///
/// `PersistentSubscriptionRunner` subscribes to a KurrentDB persistent subscription
/// and dispatches each incoming event to one or more registered projectors in parallel.
/// Replaces the per-handler `start() { Task { ... } }` boilerplate found in application
/// projection handlers.
///
/// ## Usage
///
/// ```swift
/// let runner = KurrentProjection.PersistentSubscriptionRunner(
///     client: kdbClient,
///     stream: "$ce-Order",
///     groupName: "order-projection"
/// )
/// .register(orderProjector) { record in
///     OrderProjectorInput(orderId: extractId(from: record))
/// }
///
/// try await runner.run()  // Blocks until cancelled or subscription drops.
/// ```
///
/// ## Idempotency contract
///
/// Registered projectors must be idempotent. The runner nacks the entire event on any
/// projector failure, causing KurrentDB to re-deliver the event. Already-successful
/// projectors will be invoked again on re-delivery.
///
/// `StatefulEventSourcingProjector` satisfies this contract automatically via its stored
/// revision cursor (re-invocations become no-ops). Users of the low-level closure overload
/// must ensure their `execute` closure is idempotent.
///
/// ## Lifecycle
///
/// - `run()` blocks until the parent `Task` is cancelled (returns normally) or the
///   subscription connection drops (throws).
/// - The runner does not auto-reconnect — the caller is responsible for re-running it
///   on failure (typically via Swift Service Lifecycle's `ServiceGroup`).
///
/// ## Phase 2 (deferred)
///
/// Cross-projector transactional rollback (Postgres-shared transaction) is deferred to
/// Phase 2. Phase 1 provides at-least-once delivery + projector-level idempotency only.
public enum KurrentProjection {
```

- [ ] **Step 2: Tighten the `registrationCount` visibility comment**

Find the `internal var registrationCount` declaration in `PersistentSubscriptionRunner`. Replace its comment with:

```swift
        /// Test-only — used by unit tests to verify register chaining.
        /// Internal access; not part of the public API.
        internal var registrationCount: Int {
            _registrations.withLock { $0.count }
        }
```

- [ ] **Step 3: Verify everything still passes**

```bash
swift test 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/KurrentSupport/Adapter/KurrentProjection.swift
git commit -m "[DOC] KurrentProjection — usage, idempotency contract, lifecycle"
```

---

## Task 15: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Locate the section to add to**

```bash
grep -n "## " README.md | head -20
```

Find an appropriate section (e.g., the Read Side / Projector section, or add a new one before TODO).

- [ ] **Step 2: Add a brief "Persistent Subscription Runner" section**

Edit `README.md`. Add a new section (placement at the discretion of the implementer — after the existing Projector / Read Model section is natural):

```markdown
### Persistent Subscription Runner (KurrentSupport)

Replaces hand-rolled `Task { for try await ... }` projection handlers with a
declarative runner.

```swift
import KurrentSupport
import EventSourcing

let runner = KurrentProjection.PersistentSubscriptionRunner(
    client: kdbClient,
    stream: "$ce-Order",
    groupName: "order-projection"
)
.register(orderProjectorStateful) { record in
    OrderProjectorInput(orderId: parseId(from: record))
}
.register(customerProjectorStateful) { record in
    CustomerProjectorInput(customerId: parseId(from: record))
}

try await runner.run()  // ServiceGroup-friendly; cancellation returns normally.
```

- Configurable retry via `RetryPolicy` (default: `MaxRetriesPolicy(max: 5)`).
- Subscription failure throws out of `run()` — caller decides whether to restart.
- Returning `nil` from the extract closure skips that projector for the event.
- See `docs/superpowers/specs/2026-04-28-kurrent-projection-runner-design.md`
  for the full design (including Phase 2: Postgres-shared-transaction box).
```

- [ ] **Step 3: Verify the README still renders**

```bash
head -50 README.md
```

Expected: the new section is present and well-formatted.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "[DOC] README — add Persistent Subscription Runner section"
```

---

## Final Verification

- [ ] **Step 1: Run the full test suite**

```bash
swift test 2>&1 | tail -20
```

Expected: all tests pass (unit + integration). KurrentDB must be running.

- [ ] **Step 2: Verify build with no warnings**

```bash
swift build 2>&1 | grep -iE "warning|error" || echo "no warnings"
```

Expected: `no warnings` or warnings unrelated to this change.

- [ ] **Step 3: Verify file size**

```bash
wc -l Sources/KurrentSupport/Adapter/KurrentProjection.swift
```

Expected: under 300 lines. If over, consider splitting per spec note (one file per nested type, e.g., `KurrentProjection+RetryPolicy.swift`, `KurrentProjection+PersistentSubscriptionRunner.swift`).

- [ ] **Step 4: Quick visual smoke check of the new file**

```bash
swift build --target KurrentSupport 2>&1 | tail -5
```

Expected: builds cleanly.

---

## Phase 2 Hand-off (NOT part of this plan)

After Phase 1 is shipped, open a separate brainstorm for Phase 2 (Box C — Postgres-shared transaction). Open questions per spec:

- `StatefulEventSourcingProjector.execute` — split into `stage()` + `commit()` or accept external transaction context?
- `PostgresJSONReadModelStore` — accept shared `PostgresClient` connection or `PostgresTransaction`?
- New `register(transactional:)` overload vs separate `KurrentProjection.PostgresTransactionalRunner` type?
- API-as-discipline: how does the type system force users to make the transactional/non-transactional decision explicit?

Spec section "Phase 2 (Deferred) — 已選定方向：Box C" has the design rationale.
