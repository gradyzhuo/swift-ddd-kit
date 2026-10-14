# Postgres Read Model Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Postgres read model path (TransactionalSubscriptionRunner + Postgres snapshot stores) safe for its first production user: monotonic snapshot writes, self-healing subscription groups, a backend-agnostic rebuild flow, stable read model type names, and a generator fix so `apply()` never aborts a fold.

**Architecture:** Store layer gains `SnapshotWriteMode` (mode → physical table) and uses `ReadModel.readModelTypeName`. `ReadModelPersistence` gains a backend-agnostic `ReadModelSnapshotPurging`. The `EventStoreClient` seam gains ensure/delete for persistent subscription groups plus a typed "group missing" error; both runners use it via `SubscriptionSetup`. `KurrentProjection.rebuild` orchestrates delete-group → purge → ensure-group.

**Tech Stack:** Swift 6, swift-testing, postgres-nio, swift-kurrentdb, SwiftPM build-tool plugins, DocC.

**Spec:** `docs/superpowers/specs/2026-10-14-pg-read-model-hardening-design.md`

**Worktree:** `/Volumes/Development/swift-ddd-kit/.claude/worktrees/pg-read-model-hardening` (branch `feat/pg-read-model-hardening`, based on origin/main `f9c83e6f`). Run every command from this directory.

## Global Constraints

- Default write mode is `.monotonic`; `.overwrite` table = base name, `.monotonic` table = base name + `"_monotonic"`; default base name `"read_model_snapshots"`.
- Resolved table name must match `^[a-zA-Z_][a-zA-Z0-9_$]*$` and be ≤ 63 bytes, checked with `precondition`.
- Runner default: `subscriptionSetup: .ensure(.init())` where `PersistentSubscriptionSettings()` = `startFrom: .start`, `resolveLink: true`.
- `ReadModel.readModelTypeName` default = `String(describing: Self.self)` (unchanged stored `type` values for existing users).
- Generated `apply()` must use `default: continue`.
- No query API, no JSONB indexes, no auto schema-version rebuild, no Kurrent-stream snapshot store.
- Never run integration tests against the dev KurrentDB on `:2113`. Integration runs use the throwaway containers from "Test infrastructure" below and **only** `--filter`ed suites listed in each task. Never run bare `swift test`.
- Conversation with the user is Traditional Chinese; code, comments, commit messages follow repo conventions (English code/comments; commit style `feat(scope): ...`).
- Every commit ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- swift-ddd-kit receives only generic capability — nothing NotificationContext-specific in code, tests, or docs (use Order/Summary style examples).

## Review Focus

1. **Stream hard-deleted then recreated under the same id (revision restarts at 0) in `.monotonic`** — expected: writes are skipped (documented), not an error; the docs must point to `.overwrite` or rebuild. Pinned by Task 4's "lower revision is skipped, not thrown" test.
2. **Runner restarted after the group was deleted while it was running** — expected: the run throws `.subscriptionGroupNotFound`, the group exists again afterwards, and a rerun consumes from the start. Pinned in Task 7.
3. **`rebuild` re-run after a mid-way failure (group already deleted, rows already purged)** — expected: idempotent success. Pinned in Task 9 ("rebuild twice in a row").
4. **Base table name whose `_monotonic` suffix pushes it past 63 bytes** — expected: rejected up front, never silently truncated by Postgres onto another table. Pinned in Task 3.
5. **Existing callers that never pass `subscriptionSetup` and already create their group themselves** — expected: still works (already-exists tolerated). Pinned in Task 6 (ensure twice) and Task 10 (existing integration tests that pre-create groups keep passing).

---

## Test infrastructure (used by Tasks 3–5, 10, 12)

Throwaway containers — **never** touch `development-kurrentdb.db-1` on `:2113`.

```bash
# Postgres on 5433
docker run -d --rm --name ddd-kit-hardening-pg -p 5433:5432 \
  -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres postgres:16

# KurrentDB on 2115, insecure, advertising the mapped port (otherwise gossip
# hands the client :2113 and tests would write into the dev DB)
docker run -d --rm --name ddd-kit-hardening-kdb -p 2115:2115 \
  -e KURRENTDB_INSECURE=true \
  -e KURRENTDB_HTTP_PORT=2115 \
  -e KURRENTDB_ADVERTISE_NODE_PORT_TO_CLIENT_AS=2115 \
  -e KURRENTDB_RUN_PROJECTIONS=All \
  -e KURRENTDB_START_STANDARD_PROJECTIONS=true \
  docker.kurrent.io/kurrent-latest/kurrentdb:latest

export PG_HOST=localhost PG_PORT=5433 PG_USER=postgres PG_PASSWORD=postgres PG_DATABASE=postgres
export KURRENTDB_POOL_URLS='["esdb://admin:changeit@localhost:2115?tls=false"]'
```

Verify isolation before the first integration run: `curl -s localhost:2115/gossip | grep -o '"httpEndPointPort":[0-9]*'` must print `2115`. Integration tests in this plan obtain their client **only** through `KurrentDBClient.withPooledIntegrationTestClient` (TestUtility), which uses `KURRENTDB_POOL_URLS` when set.

Teardown at the end: `docker rm -f ddd-kit-hardening-pg ddd-kit-hardening-kdb`.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/EventSourcing/Projector/ReadModel.swift` (modify) | `readModelTypeName` customization point |
| `Sources/DomainEventGenerator/Generator/Model/ProjectorGenerator.swift` (modify) | `default: continue` |
| `Sources/ProjectorGeneratorFixture/*` (create) | Plugin-generated projector used only by the behavior test |
| `Sources/ReadModelPersistencePostgres/SnapshotWriteMode.swift` (create) | Write mode enum + table name resolution |
| `Sources/ReadModelPersistencePostgres/PostgresReadModelMigration.swift` (modify) | `writeMode:` |
| `Sources/ReadModelPersistencePostgres/PostgresJSONReadModelStore.swift` (modify) | mode/table/typeName |
| `Sources/ReadModelPersistencePostgres/PostgresTransactionalReadModelStore.swift` (modify) | mode/table/typeName |
| `Sources/ReadModelPersistencePostgres/SnapshotUpsert.swift` (create) | Shared upsert SQL builder for both stores |
| `Sources/ReadModelPersistence/ReadModelSnapshotPurging.swift` (create) | Purge protocol |
| `Sources/ReadModelPersistence/InMemoryReadModelStore.swift` (modify) | conforms to purge protocol |
| `Sources/ReadModelPersistencePostgres/PostgresReadModelSnapshots.swift` (create) | Postgres purge impl |
| `Sources/KurrentSupport/Adapter/EventStoreClient.swift` (modify) | settings type, ensure/delete, error case |
| `Sources/KurrentSupport/Adapter/LiveEventStoreClient.swift` (modify) | live ensure/delete + not-found mapping |
| `Sources/KurrentSupportInMemory/InMemoryEventStoreClient.swift` (modify) | groups registry, startFrom, delete, `requireExplicitGroups` |
| `Sources/KurrentSupport/Adapter/KurrentProjection.swift` (modify) | `SubscriptionSetup`, run() ensure/recreate, sequential tx dispatch |
| `Sources/KurrentSupport/Adapter/KurrentProjection+Rebuild.swift` (create) | `KurrentProjection.rebuild` |
| `Sources/PostgresSupport/KurrentProjection+PostgresConvenience.swift` (modify) | pass `subscriptionSetup` |
| `Sources/ReadModelPersistence/ReadModelPersistence.docc/*` (create) | landing + schema evolution/rebuild article |
| `Sources/ReadModelPersistencePostgres/ReadModelPersistencePostgres.docc/*` (create) | landing + Getting Started + write modes |
| `README.md`, `docs/index.html`, `CLAUDE.md`, `scripts/emit-symbol-graphs.sh`, `Package.swift` (modify) | docs, fixture target wiring |
| `samples/KurrentTransactionalProjectionDemo/Sources/main.swift`, `samples/PostgresReadModelDemo/Sources/main.swift` (modify) | new API / defaults |

---

### Task 1: `ReadModel.readModelTypeName`

**Files:**
- Modify: `Sources/EventSourcing/Projector/ReadModel.swift`
- Test: `Tests/ReadModelPersistenceTests/ReadModelTypeNameTests.swift` (create)

**Interfaces:**
- Produces: `static var readModelTypeName: String { get }` on `ReadModel`, default `String(describing: Self.self)`. Used by Tasks 4, 5, 9.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ReadModelPersistenceTests/ReadModelTypeNameTests.swift
import Testing
import EventSourcing

private struct DefaultNamed: ReadModel, Sendable {
    let id: String
}

private struct StablyNamed: ReadModel, Sendable {
    static var readModelTypeName: String { "OrderSummary.v1" }
    let id: String
}

@Suite("ReadModel.readModelTypeName")
struct ReadModelTypeNameTests {
    @Test("Defaults to the Swift type name, matching the pre-existing stored `type` value")
    func defaultsToTypeName() {
        #expect(DefaultNamed.readModelTypeName == "DefaultNamed")
    }

    @Test("A read model can declare a stable name that survives Swift renames")
    func customName() {
        #expect(StablyNamed.readModelTypeName == "OrderSummary.v1")
    }

    @Test("Reachable through an existential metatype (used by rebuild)")
    func existentialMetatype() {
        let types: [any ReadModel.Type] = [DefaultNamed.self, StablyNamed.self]
        #expect(types.map { $0.readModelTypeName } == ["DefaultNamed", "OrderSummary.v1"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ReadModelTypeNameTests`
Expected: compile error `type 'DefaultNamed' has no member 'readModelTypeName'`.

- [ ] **Step 3: Implement**

Replace the body of `Sources/EventSourcing/Projector/ReadModel.swift` after the header comment with:

```swift
public protocol ReadModel: Codable {
    associatedtype ID: Hashable

    var id: ID { get }

    /// Name this read model is stored under (e.g. the `type` column of a Postgres
    /// snapshot table). Defaults to the Swift type name; declare a stable value so
    /// a Swift rename doesn't orphan already-stored snapshots. Changing it is a
    /// schema change — rebuild the read model afterwards.
    static var readModelTypeName: String { get }
}

extension ReadModel {
    public static var readModelTypeName: String { String(describing: Self.self) }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ReadModelTypeNameTests`
Expected: 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/EventSourcing/Projector/ReadModel.swift Tests/ReadModelPersistenceTests/ReadModelTypeNameTests.swift
git commit -m "feat(read-model): ReadModel.readModelTypeName — stable stored name, defaults to the Swift type name

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Generated `apply()` skips unlisted events instead of aborting

**Files:**
- Modify: `Sources/DomainEventGenerator/Generator/Model/ProjectorGenerator.swift:74-77`
- Create: `Sources/ProjectorGeneratorFixture/event.yaml`, `event-generator-config.yaml`, `projection-model.yaml`, `OrderSummaryFixture.swift`
- Modify: `Package.swift` (fixture target + test target), `scripts/emit-symbol-graphs.sh:29` (exclude fixture)
- Test: `Tests/DomainEventGeneratorTests/ProjectorGeneratorTests.swift` (create), `Tests/ProjectorGeneratorFixtureTests/GeneratedApplyTests.swift` (create)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: nothing consumed later.

- [ ] **Step 1: Write the failing render test**

```swift
// Tests/DomainEventGeneratorTests/ProjectorGeneratorTests.swift
import Testing
import Foundation
@testable import DomainEventGenerator

@Suite("ProjectorGenerator")
struct ProjectorGeneratorTests {

    private func render(_ yaml: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("projection-\(UUID().uuidString).yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try ProjectorGenerator(projectionModelYamlFileURL: url)
            .render(accessLevel: .internal)
            .joined(separator: "\n")
    }

    @Test("apply() skips an unlisted event (continue) instead of returning out of the whole fold")
    func unlistedEventContinues() throws {
        let output = try render("""
            OrderSummary:
              model: readModel
              events:
                - OrderCreated
                - OrderAmountUpdated
            """)
        #expect(output.contains("default:\n                continue"))
        #expect(!output.contains("default:\n                return"))
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter ProjectorGeneratorTests`
Expected: FAIL — first `#expect` false.

- [ ] **Step 3: Fix the generator**

In `ProjectorGenerator.swift`, change the emitted default branch:

```swift
            lines.append("""
            default:
                continue
            }
        }
    }
""")
```

- [ ] **Step 4: Run render test**

Run: `swift test --filter ProjectorGeneratorTests`
Expected: PASS.

- [ ] **Step 5: Add the behavior fixture target**

`Sources/ProjectorGeneratorFixture/event.yaml`:

```yaml
OrderCreated:
  kind: createdEvent
  aggregateRootId:
    alias: orderId
  properties:
    customerId: String
    totalAmount: Double

OrderNoteAdded:
  aggregateRootId:
    alias: orderId
  properties:
    note: String

OrderAmountUpdated:
  aggregateRootId:
    alias: orderId
  properties:
    newAmount: Double
```

`Sources/ProjectorGeneratorFixture/event-generator-config.yaml`:

```yaml
accessModifier: public
```

`Sources/ProjectorGeneratorFixture/projection-model.yaml` (deliberately omits `OrderNoteAdded`):

```yaml
OrderSummary:
  model: readModel
  events:
    - OrderCreated
    - OrderAmountUpdated
```

`Sources/ProjectorGeneratorFixture/OrderSummaryFixture.swift`:

```swift
// Fixture for Tests/ProjectorGeneratorFixtureTests — exercises the projector
// protocol the ModelGeneratorPlugin generates from projection-model.yaml.
import Foundation
import DDDCore
import EventSourcing
import KurrentSupport

public struct OrderSummary: ReadModel, Codable, Sendable {
    public let id: String
    public var customerId: String = ""
    public var totalAmount: Double = 0
}

public struct OrderSummaryInput: CQRSProjectorInput {
    public let id: String
    public init(id: String) { self.id = id }
}

public struct OrderSummaryProjector: OrderSummaryProjectorProtocol {
    public typealias ReadModelType = OrderSummary
    public typealias Input = OrderSummaryInput
    public typealias Store = InMemoryStorageCoordinator<CustomMetadata>

    public static var categoryRule: StreamCategoryRule { .custom("Order") }

    public let store: InMemoryStorageCoordinator<CustomMetadata>

    public init(store: InMemoryStorageCoordinator<CustomMetadata>) { self.store = store }

    public func buildReadModel(input: Input) throws -> OrderSummary? { OrderSummary(id: input.id) }

    public func when(readModel: inout OrderSummary, event: OrderCreated) throws {
        readModel.customerId = event.customerId
        readModel.totalAmount = event.totalAmount
    }

    public func when(readModel: inout OrderSummary, event: OrderAmountUpdated) throws {
        readModel.totalAmount = event.newAmount
    }
}
```

In `Package.swift`, next to `TemplateVariablesDemo`, add:

```swift
        .target(
            name: "ProjectorGeneratorFixture",
            dependencies: ["DDDKit"],
            plugins: ["DomainEventGeneratorPlugin", "ModelGeneratorPlugin"]),
        .testTarget(
            name: "ProjectorGeneratorFixtureTests",
            dependencies: ["ProjectorGeneratorFixture", "DDDKit"]),
```

In `scripts/emit-symbol-graphs.sh:29`: `EXCLUDED=" DDDKit generate DDDKitCLI TemplateVariablesDemo ProjectorGeneratorFixture "`.

Run: `swift build --target ProjectorGeneratorFixture`
Expected: builds. If the generated file fails to import a module, mirror `samples/PostgresReadModelDemo` (same yaml shape, builds with the `DDDKit` product) — add the missing module name under `dependencies:` in `event-generator-config.yaml`.

- [ ] **Step 6: Write the behavior test**

```swift
// Tests/ProjectorGeneratorFixtureTests/GeneratedApplyTests.swift
import Testing
import DDDKit
import ProjectorGeneratorFixture

@Suite("Generated projector apply()")
struct GeneratedApplyTests {
    @Test("An unlisted event in the middle of a batch does not drop the listed events after it")
    func unlistedEventInMiddle() throws {
        let projector = OrderSummaryProjector(store: .init())
        var model = OrderSummary(id: "o-1")
        let events: [any DomainEvent] = [
            OrderCreated(orderId: "o-1", customerId: "c-1", totalAmount: 100),
            OrderNoteAdded(orderId: "o-1", note: "not projected"),
            OrderAmountUpdated(orderId: "o-1", newAmount: 250),
        ]

        try projector.apply(readModel: &model, events: events)

        #expect(model.customerId == "c-1")
        #expect(model.totalAmount == 250)
    }
}
```

- [ ] **Step 7: Verify it fails against the old generator, passes against the new one**

Temporarily change `continue` back to `return` in `ProjectorGenerator.swift` (Step 3's line), then
Run: `swift test --filter GeneratedApplyTests`
Expected: FAIL (`totalAmount` is `100`, the fold stopped at `OrderNoteAdded`).
Restore `continue`, then
Run: `swift test --filter GeneratedApplyTests`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/DomainEventGenerator Sources/ProjectorGeneratorFixture Tests/DomainEventGeneratorTests/ProjectorGeneratorTests.swift Tests/ProjectorGeneratorFixtureTests Package.swift scripts/emit-symbol-graphs.sh
git commit -m "fix(generator): generated apply() skips unlisted events instead of aborting the fold

A read model listing only some of a stream's events lost every listed event
after the first unlisted one, while the stored revision still advanced.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `SnapshotWriteMode`, table resolution, migration

**Files:**
- Create: `Sources/ReadModelPersistencePostgres/SnapshotWriteMode.swift`
- Modify: `Sources/ReadModelPersistencePostgres/PostgresReadModelMigration.swift`
- Test: `Tests/ReadModelPersistencePostgresIntegrationTests/SnapshotWriteModeTests.swift` (create)

**Interfaces:**
- Produces:
  - `public enum SnapshotWriteMode: Sendable, Equatable { case overwrite, monotonic }`
  - `enum SnapshotTable { static func resolve(baseName: String, mode: SnapshotWriteMode) -> String }` (internal; preconditions on identifier + 63-byte limit)
  - `PostgresReadModelMigration.createTable(on:tableName:writeMode:)` — `writeMode` defaults to `.monotonic`.

- [ ] **Step 1: Write failing tests**

```swift
// Tests/ReadModelPersistencePostgresIntegrationTests/SnapshotWriteModeTests.swift
import Testing
import Foundation
import PostgresNIO
@testable import ReadModelPersistencePostgres

@Suite("SnapshotWriteMode table resolution")
struct SnapshotWriteModeTests {
    @Test("overwrite keeps the base name; monotonic appends _monotonic")
    func resolution() {
        #expect(SnapshotTable.resolve(baseName: "read_model_snapshots", mode: .overwrite) == "read_model_snapshots")
        #expect(SnapshotTable.resolve(baseName: "read_model_snapshots", mode: .monotonic) == "read_model_snapshots_monotonic")
    }

    @Test("A base name that only exceeds 63 bytes once suffixed is rejected")
    func suffixedLengthRejected() async {
        let base = String(repeating: "a", count: 60) // 60 + "_monotonic" = 70
        await #expect(processExitsWith: .failure) {
            _ = SnapshotTable.resolve(baseName: base, mode: .monotonic)
        }
    }

    @Test("createTable builds the table for the chosen mode")
    func createTablePerMode() async throws {
        let client = PostgresClient(configuration: .testDefault)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            let base = "wm_\(UUID().uuidString.prefix(8).lowercased())"
            try await PostgresReadModelMigration.createTable(on: client, tableName: base, writeMode: .monotonic)
            let rows = try await client.query("SELECT to_regclass(\(base + "_monotonic"))::text, to_regclass(\(base))::text")
            for try await (mono, plain) in rows.decode((String?, String?).self) {
                #expect(mono == base + "_monotonic")
                #expect(plain == nil)
            }
            try await client.query("DROP TABLE \(unescaped: base + "_monotonic")")
            group.cancelAll()
        }
    }
}

extension PostgresClient.Configuration {
    /// Shared by this test target; reads PG_* env vars (see plan "Test infrastructure").
    static var testDefault: Self {
        let env = ProcessInfo.processInfo.environment
        return .init(
            host: env["PG_HOST"] ?? "localhost",
            port: Int(env["PG_PORT"] ?? "5432") ?? 5432,
            username: env["PG_USER"] ?? "postgres",
            password: env["PG_PASSWORD"] ?? "postgres",
            database: env["PG_DATABASE"] ?? "postgres",
            tls: .disable
        )
    }
}
```

(`#expect(processExitsWith:)` requires swift-testing exit tests, available with Swift 6.2 toolchains on macOS/Linux. If the toolchain in use rejects it, delete only that test and add a comment in `SnapshotTable.resolve` noting the precondition is untested; do not weaken the precondition.)

- [ ] **Step 2: Run to verify failure**

Start the containers from "Test infrastructure", export the env vars.
Run: `swift test --filter SnapshotWriteModeTests`
Expected: compile error — `SnapshotTable` / `writeMode:` missing.

- [ ] **Step 3: Implement**

```swift
// Sources/ReadModelPersistencePostgres/SnapshotWriteMode.swift
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
```

Replace `PostgresReadModelMigration.createTable`:

```swift
    /// Creates the snapshot table for `writeMode` if it does not already exist.
    ///
    /// Idempotent — safe to call on every startup. The physical table is
    /// `tableName` for `.overwrite` and `tableName + "_monotonic"` for `.monotonic`.
    public static func createTable(
        on client: PostgresClient,
        tableName: String = "read_model_snapshots",
        writeMode: SnapshotWriteMode = .monotonic
    ) async throws {
        let table = SnapshotTable.resolve(baseName: tableName, mode: writeMode)
        try await client.query("""
            CREATE TABLE IF NOT EXISTS \(unescaped: table) (
                id         TEXT        NOT NULL,
                type       TEXT        NOT NULL,
                data       JSONB       NOT NULL,
                revision   BIGINT      NOT NULL,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                PRIMARY KEY (id, type)
            )
            """)
    }
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter SnapshotWriteModeTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ReadModelPersistencePostgres/SnapshotWriteMode.swift Sources/ReadModelPersistencePostgres/PostgresReadModelMigration.swift Tests/ReadModelPersistencePostgresIntegrationTests/SnapshotWriteModeTests.swift
git commit -m "feat(pg-read-model): SnapshotWriteMode — overwrite/monotonic, each in its own table

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Both Postgres stores honor mode, table name, and `readModelTypeName`

**Files:**
- Create: `Sources/ReadModelPersistencePostgres/SnapshotUpsert.swift`
- Modify: `Sources/ReadModelPersistencePostgres/PostgresJSONReadModelStore.swift`, `Sources/ReadModelPersistencePostgres/PostgresTransactionalReadModelStore.swift`
- Modify tests: `Tests/ReadModelPersistencePostgresIntegrationTests/PostgresJSONReadModelStoreTests.swift`, `PostgresTransactionalReadModelStoreTests.swift`

**Interfaces:**
- Consumes: `SnapshotWriteMode`, `SnapshotTable.resolve` (Task 3); `Model.readModelTypeName` (Task 1).
- Produces:
  - `PostgresJSONReadModelStore<Model>.init(client:tableName: = "read_model_snapshots", writeMode: = .monotonic)`
  - `PostgresTransactionalReadModelStore<Model>.init(tableName: = "read_model_snapshots", writeMode: = .monotonic)`
  - `enum SnapshotUpsert { static func query(table:id:typeName:json:revision:mode:) -> PostgresQuery }` (internal)

- [ ] **Step 1: Update the JSON store test helper and add mode tests**

In `PostgresJSONReadModelStoreTests.swift` replace `withStore` (it hardcoded `ddd/ddd@5432` and a hand-made table) with:

```swift
private func withStore<T>(
    writeMode: SnapshotWriteMode = .monotonic,
    _ body: (PostgresJSONReadModelStore<TestModel>) async throws -> T
) async throws -> T {
    let client = PostgresClient(configuration: .testDefault)
    let task = Task { await client.run() }
    defer { task.cancel() }

    try await PostgresReadModelMigration.createTable(
        on: client, tableName: "read_model_snapshots_test", writeMode: writeMode
    )
    let store = PostgresJSONReadModelStore<TestModel>(
        client: client, tableName: "read_model_snapshots_test", writeMode: writeMode
    )
    return try await body(store)
}
```

Append to the suite:

```swift
    @Test("monotonic: an older revision is skipped, not thrown, and the newer snapshot survives")
    func monotonicSkipsOlder() async throws {
        let id = UUID().uuidString
        try await withStore(writeMode: .monotonic) { store in
            try await store.save(readModel: TestModel(id: id, value: "rev6"), revision: 6)
            try await store.save(readModel: TestModel(id: id, value: "rev5"), revision: 5)
            let stored = try await store.fetch(byId: id)
            #expect(stored?.readModel.value == "rev6")
            #expect(stored?.revision == 6)
            try await store.delete(byId: id)
        }
    }

    @Test("monotonic: an equal revision is skipped")
    func monotonicSkipsEqual() async throws {
        let id = UUID().uuidString
        try await withStore(writeMode: .monotonic) { store in
            try await store.save(readModel: TestModel(id: id, value: "first"), revision: 3)
            try await store.save(readModel: TestModel(id: id, value: "second"), revision: 3)
            #expect(try await store.fetch(byId: id)?.readModel.value == "first")
            try await store.delete(byId: id)
        }
    }

    @Test("overwrite: the last write wins even with an older revision")
    func overwriteLastWins() async throws {
        let id = UUID().uuidString
        try await withStore(writeMode: .overwrite) { store in
            try await store.save(readModel: TestModel(id: id, value: "rev6"), revision: 6)
            try await store.save(readModel: TestModel(id: id, value: "rev0"), revision: 0)
            let stored = try await store.fetch(byId: id)
            #expect(stored?.readModel.value == "rev0")
            #expect(stored?.revision == 0)
            try await store.delete(byId: id)
        }
    }

    @Test("Modes never share rows: a monotonic write is invisible to an overwrite store")
    func modesUseSeparateTables() async throws {
        let id = UUID().uuidString
        try await withStore(writeMode: .monotonic) { mono in
            try await mono.save(readModel: TestModel(id: id, value: "mono"), revision: 1)
            try await withStore(writeMode: .overwrite) { over in
                #expect(try await over.fetch(byId: id) == nil)
            }
            try await mono.delete(byId: id)
        }
    }

    @Test("Rows are keyed by readModelTypeName")
    func usesReadModelTypeName() async throws {
        let id = UUID().uuidString
        let client = PostgresClient(configuration: .testDefault)
        let task = Task { await client.run() }
        defer { task.cancel() }
        try await PostgresReadModelMigration.createTable(on: client, tableName: "read_model_snapshots_test")
        let store = PostgresJSONReadModelStore<RenamedModel>(client: client, tableName: "read_model_snapshots_test")
        try await store.save(readModel: RenamedModel(id: id), revision: 1)
        let rows = try await client.query(
            "SELECT type FROM read_model_snapshots_test_monotonic WHERE id = \(id)"
        )
        for try await (type,) in rows.decode((String,).self) { #expect(type == "Stable.Name") }
        try await store.delete(byId: id)
    }
```

and the fixture at the top of the file:

```swift
private struct RenamedModel: ReadModel, Sendable {
    static var readModelTypeName: String { "Stable.Name" }
    typealias ID = String
    let id: String
}
```

- [ ] **Step 2: Add transactional store tests**

In `PostgresTransactionalReadModelStoreTests.swift`, replace `makeClient()` body with `PostgresClient(configuration: .testDefault)` and append:

```swift
    @Test("monotonic: a stale commit does not roll the snapshot back (two consumers, out of order)")
    func monotonicStaleCommitSkipped() async throws {
        let client = Self.makeClient()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            try await PostgresReadModelMigration.createTable(on: client)
            let store = PostgresTransactionalReadModelStore<DemoModel>()
            let provider = PostgresTransactionProvider(client: client)
            let id = "tx-mono-\(UUID().uuidString.prefix(8))"

            try await provider.withTransaction { conn in
                try await store.save(readModel: DemoModel(id: id, value: "rev6"), revision: 6, in: conn)
            }
            try await provider.withTransaction { conn in
                try await store.save(readModel: DemoModel(id: id, value: "rev5"), revision: 5, in: conn)
            }
            let stored: StoredReadModel<DemoModel>? = try await provider.withTransaction { conn in
                try await store.fetch(byId: id, in: conn)
            }
            #expect(stored?.readModel.value == "rev6")
            #expect(stored?.revision == 6)
            group.cancelAll()
        }
    }

    @Test("Custom table name and overwrite mode are honored")
    func customTableOverwrite() async throws {
        let client = Self.makeClient()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            let table = "tx_custom_\(UUID().uuidString.prefix(8).lowercased())"
            try await PostgresReadModelMigration.createTable(on: client, tableName: table, writeMode: .overwrite)
            let store = PostgresTransactionalReadModelStore<DemoModel>(tableName: table, writeMode: .overwrite)
            let provider = PostgresTransactionProvider(client: client)
            let id = "tx-custom-\(UUID().uuidString.prefix(8))"

            try await provider.withTransaction { conn in
                try await store.save(readModel: DemoModel(id: id, value: "rev6"), revision: 6, in: conn)
                try await store.save(readModel: DemoModel(id: id, value: "rev1"), revision: 1, in: conn)
            }
            let stored: StoredReadModel<DemoModel>? = try await provider.withTransaction { conn in
                try await store.fetch(byId: id, in: conn)
            }
            #expect(stored?.readModel.value == "rev1")
            try await client.query("DROP TABLE \(unescaped: table)")
            group.cancelAll()
        }
    }
```

- [ ] **Step 3: Run to verify failure**

Run: `swift test --filter "PostgresJSONReadModelStoreTests|PostgresTransactionalReadModelStoreTests"`
Expected: compile errors (`writeMode:` / `tableName:` labels missing).

- [ ] **Step 4: Implement the shared upsert**

```swift
// Sources/ReadModelPersistencePostgres/SnapshotUpsert.swift
import PostgresNIO

/// The single upsert statement both Postgres snapshot stores issue.
enum SnapshotUpsert {
    static func query(
        table: String,
        id: String,
        typeName: String,
        json: String,
        revision: Int64,
        mode: SnapshotWriteMode
    ) -> PostgresQuery {
        switch mode {
        case .overwrite:
            return """
                INSERT INTO \(unescaped: table) (id, type, data, revision, updated_at)
                VALUES (\(id), \(typeName), \(json)::jsonb, \(revision), now())
                ON CONFLICT (id, type) DO UPDATE SET
                    data = EXCLUDED.data,
                    revision = EXCLUDED.revision,
                    updated_at = EXCLUDED.updated_at
                """
        case .monotonic:
            return """
                INSERT INTO \(unescaped: table) (id, type, data, revision, updated_at)
                VALUES (\(id), \(typeName), \(json)::jsonb, \(revision), now())
                ON CONFLICT (id, type) DO UPDATE SET
                    data = EXCLUDED.data,
                    revision = EXCLUDED.revision,
                    updated_at = EXCLUDED.updated_at
                WHERE \(unescaped: table).revision < EXCLUDED.revision
                RETURNING 1
                """
        }
    }
}
```

`RETURNING 1` yields a row only when the insert/update happened, so a store can tell a skipped
monotonic write (zero rows) from an applied one without extra round trips.

- [ ] **Step 5: Rewire `PostgresJSONReadModelStore`**

Replace stored properties + init:

```swift
    private let client: PostgresClient
    private let typeName: String
    private let tableName: String
    private let writeMode: SnapshotWriteMode

    /// - Parameters:
    ///   - tableName: Base table name; the physical table depends on `writeMode`
    ///     (see ``SnapshotWriteMode``). Create it with
    ///     `PostgresReadModelMigration.createTable(on:tableName:writeMode:)`.
    ///   - writeMode: Defaults to `.monotonic`.
    public init(
        client: PostgresClient,
        tableName: String = "read_model_snapshots",
        writeMode: SnapshotWriteMode = .monotonic
    ) {
        self.client = client
        self.typeName = Model.readModelTypeName
        self.tableName = SnapshotTable.resolve(baseName: tableName, mode: writeMode)
        self.writeMode = writeMode
    }
```

Replace the `try await client.query("""INSERT ...""")` inside `save` with:

```swift
            let rows = try await client.query(SnapshotUpsert.query(
                table: tableName, id: readModel.id, typeName: typeName,
                json: jsonString, revision: rev, mode: writeMode
            ))
            if writeMode == .monotonic, try await rows.collect().isEmpty {
                logger.debug("skipped stale snapshot write", metadata: [
                    "id": "\(readModel.id)", "type": "\(typeName)", "revision": "\(revision)",
                ])
            }
```

Add `import Logging` and a stored `private let logger = Logger(label: "PostgresJSONReadModelStore")` to the struct.

- [ ] **Step 6: Rewire `PostgresTransactionalReadModelStore`**

Replace `public init() {}` with:

```swift
    private let tableName: String
    private let writeMode: SnapshotWriteMode
    private let logger = Logger(label: "PostgresTransactionalReadModelStore")

    /// - Parameters:
    ///   - tableName: Base table name; the physical table depends on `writeMode`
    ///     (see ``SnapshotWriteMode``).
    ///   - writeMode: Defaults to `.monotonic`.
    public init(tableName: String = "read_model_snapshots", writeMode: SnapshotWriteMode = .monotonic) {
        self.tableName = SnapshotTable.resolve(baseName: tableName, mode: writeMode)
        self.writeMode = writeMode
    }
```

In `save`: `let typeName = Model.readModelTypeName`, and replace the query call with:

```swift
            let rows = try await transaction.query(
                SnapshotUpsert.query(
                    table: tableName, id: readModel.id, typeName: typeName,
                    json: json, revision: revBits, mode: writeMode
                ),
                logger: logger
            )
            if writeMode == .monotonic, try await rows.collect().isEmpty {
                logger.debug("skipped stale snapshot write", metadata: [
                    "id": "\(readModel.id)", "type": "\(typeName)", "revision": "\(revision)",
                ])
            }
```

In `fetch`: `let typeName = Model.readModelTypeName`, and change `FROM read_model_snapshots` to `FROM \(unescaped: tableName)`, `logger: logger`. Update the type doc comment: replace "for the shared `read_model_snapshots` table" with "for a Postgres snapshot table (see ``SnapshotWriteMode`` for which one)" and "keyed by `String(describing: Model.self)`" with "keyed by `Model.readModelTypeName`". Update the same phrase in the file header comment.

- [ ] **Step 7: Run tests**

Run: `swift test --filter "PostgresJSONReadModelStoreTests|PostgresTransactionalReadModelStoreTests|SnapshotWriteModeTests"`
Expected: all PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/ReadModelPersistencePostgres Tests/ReadModelPersistencePostgresIntegrationTests
git commit -m "feat(pg-read-model): stores take writeMode + tableName, key rows by readModelTypeName

Default .monotonic: a stale commit (out-of-order redelivery, a second
consumer) no longer rolls a newer snapshot back. PostgresTransactionalReadModelStore's
table name is now configurable.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: `ReadModelSnapshotPurging` + in-memory and Postgres implementations

**Files:**
- Create: `Sources/ReadModelPersistence/ReadModelSnapshotPurging.swift`, `Sources/ReadModelPersistencePostgres/PostgresReadModelSnapshots.swift`
- Modify: `Sources/ReadModelPersistence/InMemoryReadModelStore.swift`
- Test: `Tests/ReadModelPersistenceTests/InMemoryReadModelStorePurgeTests.swift` (create), `Tests/ReadModelPersistencePostgresIntegrationTests/PostgresReadModelSnapshotsTests.swift` (create)

**Interfaces:**
- Consumes: `readModelTypeName` (Task 1), `SnapshotTable` (Task 3).
- Produces:
  - `public protocol ReadModelSnapshotPurging: Sendable { func purgeSnapshots(ofTypes typeNames: [String]) async throws }`
  - `extension InMemoryReadModelStore: ReadModelSnapshotPurging`
  - `public struct PostgresReadModelSnapshots: ReadModelSnapshotPurging { init(client:tableName: = "read_model_snapshots", writeMode: = .monotonic) }`

- [ ] **Step 1: Failing in-memory test**

```swift
// Tests/ReadModelPersistenceTests/InMemoryReadModelStorePurgeTests.swift
import Testing
import EventSourcing
import ReadModelPersistence

private struct Summary: ReadModel, Sendable { let id: String }

@Suite("InMemoryReadModelStore — purge")
struct InMemoryReadModelStorePurgeTests {
    @Test("Purging its own type empties the store")
    func purgesOwnType() async throws {
        let store = InMemoryReadModelStore<Summary>()
        try await store.save(readModel: Summary(id: "a"), revision: 1)
        try await store.purgeSnapshots(ofTypes: [Summary.readModelTypeName])
        #expect(try await store.fetch(byId: "a") == nil)
    }

    @Test("Purging another type leaves the store untouched")
    func ignoresOtherTypes() async throws {
        let store = InMemoryReadModelStore<Summary>()
        try await store.save(readModel: Summary(id: "a"), revision: 1)
        try await store.purgeSnapshots(ofTypes: ["SomethingElse"])
        #expect(try await store.fetch(byId: "a")?.revision == 1)
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `swift test --filter InMemoryReadModelStorePurgeTests`
Expected: compile error — `purgeSnapshots` missing.

- [ ] **Step 3: Implement protocol + in-memory conformance**

```swift
// Sources/ReadModelPersistence/ReadModelSnapshotPurging.swift
/// A snapshot backend that can drop every snapshot of the given read model types at once.
///
/// Snapshots are a disposable projection cache — never the source of truth — so the
/// recovery path for any read model schema change is "purge, then replay from the start".
/// `KurrentProjection.rebuild` drives that flow through this protocol, which keeps it
/// independent of where snapshots live (Postgres, memory, or a future stream-backed store).
public protocol ReadModelSnapshotPurging: Sendable {
    /// Deletes every snapshot whose read model type name (``ReadModel/readModelTypeName``)
    /// is in `typeNames`. Idempotent: purging types with no snapshots succeeds.
    func purgeSnapshots(ofTypes typeNames: [String]) async throws
}
```

Append to `InMemoryReadModelStore.swift`:

```swift
extension InMemoryReadModelStore: ReadModelSnapshotPurging {
    public func purgeSnapshots(ofTypes typeNames: [String]) async throws {
        guard typeNames.contains(Model.readModelTypeName) else { return }
        storage.removeAll()
    }
}
```

(`storage` is `private`; an extension in the same file can access it.)

- [ ] **Step 4: Run in-memory tests**

Run: `swift test --filter InMemoryReadModelStorePurgeTests`
Expected: PASS.

- [ ] **Step 5: Failing Postgres test**

```swift
// Tests/ReadModelPersistencePostgresIntegrationTests/PostgresReadModelSnapshotsTests.swift
import Testing
import Foundation
import PostgresNIO
import EventSourcing
import ReadModelPersistence
@testable import ReadModelPersistencePostgres

private struct Kept: ReadModel, Sendable { let id: String }
private struct Purged: ReadModel, Sendable { let id: String }

@Suite("PostgresReadModelSnapshots", .serialized)
struct PostgresReadModelSnapshotsTests {
    @Test("Purges only the listed types, only in the table of its write mode")
    func purgesListedTypesOnly() async throws {
        let client = PostgresClient(configuration: .testDefault)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            let base = "purge_\(UUID().uuidString.prefix(8).lowercased())"
            try await PostgresReadModelMigration.createTable(on: client, tableName: base, writeMode: .monotonic)
            let kept = PostgresJSONReadModelStore<Kept>(client: client, tableName: base)
            let purged = PostgresJSONReadModelStore<Purged>(client: client, tableName: base)
            try await kept.save(readModel: Kept(id: "1"), revision: 1)
            try await purged.save(readModel: Purged(id: "1"), revision: 1)

            let snapshots = PostgresReadModelSnapshots(client: client, tableName: base)
            try await snapshots.purgeSnapshots(ofTypes: [Purged.readModelTypeName])
            try await snapshots.purgeSnapshots(ofTypes: [Purged.readModelTypeName]) // idempotent

            #expect(try await kept.fetch(byId: "1")?.revision == 1)
            #expect(try await purged.fetch(byId: "1") == nil)
            try await client.query("DROP TABLE \(unescaped: base + "_monotonic")")
            group.cancelAll()
        }
    }
}
```

- [ ] **Step 6: Run, expect failure**

Run: `swift test --filter PostgresReadModelSnapshotsTests`
Expected: compile error — `PostgresReadModelSnapshots` missing.

- [ ] **Step 7: Implement**

```swift
// Sources/ReadModelPersistencePostgres/PostgresReadModelSnapshots.swift
import PostgresNIO
import ReadModelPersistence

/// Table-level operations on a Postgres snapshot table — currently purging, used by
/// `KurrentProjection.rebuild`.
///
/// Resolves the same physical table as the stores for a given
/// `(tableName, writeMode)` pair, so pass the values your stores use.
public struct PostgresReadModelSnapshots: ReadModelSnapshotPurging {
    private let client: PostgresClient
    private let tableName: String

    public init(
        client: PostgresClient,
        tableName: String = "read_model_snapshots",
        writeMode: SnapshotWriteMode = .monotonic
    ) {
        self.client = client
        self.tableName = SnapshotTable.resolve(baseName: tableName, mode: writeMode)
    }

    public func purgeSnapshots(ofTypes typeNames: [String]) async throws {
        guard !typeNames.isEmpty else { return }
        try await client.query(
            "DELETE FROM \(unescaped: tableName) WHERE type = ANY(\(typeNames))"
        )
    }
}
```

- [ ] **Step 8: Run tests**

Run: `swift test --filter "PostgresReadModelSnapshotsTests|InMemoryReadModelStorePurgeTests"`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add Sources/ReadModelPersistence Sources/ReadModelPersistencePostgres/PostgresReadModelSnapshots.swift Tests/ReadModelPersistenceTests/InMemoryReadModelStorePurgeTests.swift Tests/ReadModelPersistencePostgresIntegrationTests/PostgresReadModelSnapshotsTests.swift
git commit -m "feat(read-model): ReadModelSnapshotPurging — backend-agnostic snapshot purge (in-memory, Postgres)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: `EventStoreClient` subscription-group lifecycle (seam + in-memory + live)

**Files:**
- Modify: `Sources/KurrentSupport/Adapter/EventStoreClient.swift`, `Sources/KurrentSupport/Adapter/LiveEventStoreClient.swift`, `Sources/KurrentSupportInMemory/InMemoryEventStoreClient.swift`
- Test: `Tests/KurrentSupportInMemoryTests/InMemorySubscriptionGroupTests.swift` (create)

**Interfaces:**
- Produces (all in `KurrentSupport`):

```swift
public struct PersistentSubscriptionSettings: Sendable, Equatable {
    public enum StartPosition: Sendable, Equatable { case start, end }
    public var startFrom: StartPosition
    public var resolveLink: Bool
    public init(startFrom: StartPosition = .start, resolveLink: Bool = true)
}
// EventStoreClient additions:
func ensurePersistentSubscription(stream: String, group: String, settings: PersistentSubscriptionSettings) async throws
func deletePersistentSubscription(stream: String, group: String) async throws
// EventStoreClientError addition:
case subscriptionGroupNotFound(stream: String, group: String)
// InMemoryEventStoreClient:
public init(deliveryDelay: Duration = .zero, requireExplicitGroups: Bool = false)
public func persistentSubscriptionExists(stream: String, group: String) -> Bool
```

- [ ] **Step 1: Failing in-memory tests**

```swift
// Tests/KurrentSupportInMemoryTests/InMemorySubscriptionGroupTests.swift
import Testing
import Foundation
import KurrentDB
import KurrentSupport
import KurrentSupportInMemory

private struct Ping: Codable, Sendable { let n: Int }

private func append(_ client: InMemoryEventStoreClient, _ n: Int) async throws {
    _ = try await client.append(
        events: [EventData(eventType: "Ping", model: Ping(n: n))],
        toStream: "Ping-\(n)", category: "Ping", expectedRevision: .noStream
    )
}

private func first(_ session: any PersistentSubscriptionSession) async throws -> Int? {
    for try await delivery in session.events {
        return try delivery.event.decode(to: Ping.self)?.n
    }
    return nil
}

@Suite("InMemoryEventStoreClient — subscription groups")
struct InMemorySubscriptionGroupTests {

    @Test("requireExplicitGroups: subscribing to a missing group throws subscriptionGroupNotFound")
    func missingGroupThrows() async throws {
        let client = InMemoryEventStoreClient(requireExplicitGroups: true)
        await #expect(throws: EventStoreClientError.subscriptionGroupNotFound(stream: "$ce-Ping", group: "g")) {
            _ = try await client.subscribePersistent(stream: "$ce-Ping", group: "g")
        }
    }

    @Test("ensure is idempotent and startFrom .start replays history")
    func ensureStartReplays() async throws {
        let client = InMemoryEventStoreClient(requireExplicitGroups: true)
        try await append(client, 1)
        try await client.ensurePersistentSubscription(stream: "$ce-Ping", group: "g", settings: .init())
        try await client.ensurePersistentSubscription(stream: "$ce-Ping", group: "g", settings: .init())
        let session = try await client.subscribePersistent(stream: "$ce-Ping", group: "g")
        #expect(try await first(session) == 1)
    }

    @Test("startFrom .end skips history")
    func ensureEndSkipsHistory() async throws {
        let client = InMemoryEventStoreClient(requireExplicitGroups: true)
        try await append(client, 1)
        try await client.ensurePersistentSubscription(stream: "$ce-Ping", group: "g", settings: .init(startFrom: .end))
        let session = try await client.subscribePersistent(stream: "$ce-Ping", group: "g")
        try await append(client, 2)
        #expect(try await first(session) == 2)
    }

    @Test("delete ends live sessions with subscriptionGroupNotFound; deleting again is tolerated")
    func deleteEndsSessions() async throws {
        let client = InMemoryEventStoreClient(requireExplicitGroups: true)
        try await client.ensurePersistentSubscription(stream: "$ce-Ping", group: "g", settings: .init())
        let session = try await client.subscribePersistent(stream: "$ce-Ping", group: "g")
        try await client.deletePersistentSubscription(stream: "$ce-Ping", group: "g")
        try await client.deletePersistentSubscription(stream: "$ce-Ping", group: "g")
        #expect(await client.persistentSubscriptionExists(stream: "$ce-Ping", group: "g") == false)
        await #expect(throws: EventStoreClientError.subscriptionGroupNotFound(stream: "$ce-Ping", group: "g")) {
            _ = try await first(session)
        }
    }

    @Test("Default (requireExplicitGroups: false) still auto-creates on subscribe, replaying from start")
    func defaultAutoCreates() async throws {
        let client = InMemoryEventStoreClient()
        try await append(client, 1)
        let session = try await client.subscribePersistent(stream: "$ce-Ping", group: "g")
        #expect(try await first(session) == 1)
        #expect(await client.persistentSubscriptionExists(stream: "$ce-Ping", group: "g"))
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `swift test --filter InMemorySubscriptionGroupTests`
Expected: compile errors.

- [ ] **Step 3: Seam additions in `EventStoreClient.swift`**

Add above `public protocol EventStoreClient`:

```swift
/// Settings used when a persistent subscription group is created. They apply only at
/// creation — an existing group keeps its server-side settings and checkpoint.
public struct PersistentSubscriptionSettings: Sendable, Equatable {
    public enum StartPosition: Sendable, Equatable { case start, end }

    /// Where a newly created group starts. `.start` (default) is what a read model
    /// needs: a fresh or recreated group rebuilds every snapshot; already-applied
    /// events are no-ops thanks to the stored revision cursor.
    public var startFrom: StartPosition
    /// Required for `$ce-<Category>`/`$et-<Type>` system streams so delivered events
    /// carry the original stream name. Default `true`.
    public var resolveLink: Bool

    public init(startFrom: StartPosition = .start, resolveLink: Bool = true) {
        self.startFrom = startFrom
        self.resolveLink = resolveLink
    }
}
```

Add to the protocol after `subscribePersistent`:

```swift
    /// Creates the persistent subscription group. An already-existing group is
    /// tolerated and left unchanged.
    func ensurePersistentSubscription(stream: String, group: String, settings: PersistentSubscriptionSettings) async throws
    /// Deletes the persistent subscription group. A missing group is tolerated.
    func deletePersistentSubscription(stream: String, group: String) async throws
```

Document on `subscribePersistent`: `/// Throws `EventStoreClientError.subscriptionGroupNotFound` — at subscribe time or from `events` — when the group does not exist (or is deleted while subscribed).`

Add to `EventStoreClientError`:

```swift
    /// The persistent subscription group does not exist — never created, or deleted
    /// (e.g. the KurrentDB instance was recreated). Raised by `subscribePersistent`
    /// or from a session's `events` when the group disappears mid-subscription.
    case subscriptionGroupNotFound(stream: String, group: String)
```

- [ ] **Step 4: In-memory implementation**

In `InMemoryEventStoreClient`:

1. Add stored properties and replace `init`:

```swift
    private var groupSettings: [SubscriptionKey: PersistentSubscriptionSettings] = [:]
    private let requireExplicitGroups: Bool

    /// - Parameters:
    ///   - deliveryDelay: (unchanged doc)
    ///   - requireExplicitGroups: `false` (default) creates a group on first subscribe,
    ///     replaying from the start — the pre-existing behavior. `true` makes
    ///     `subscribePersistent` throw `.subscriptionGroupNotFound` for a group that was
    ///     never ensured (or was deleted), mirroring a real cluster — use it to test
    ///     group creation/recreation logic.
    public init(deliveryDelay: Duration = .zero, requireExplicitGroups: Bool = false) {
        self.deliveryDelay = deliveryDelay
        self.requireExplicitGroups = requireExplicitGroups
    }
```

2. Factor the `$`-prefix validation at the top of `subscribePersistent` into `private func validateSubscriptionTarget(_ target: String) throws` and call it from both `subscribePersistent` and `ensurePersistentSubscription`.

3. Replace the body after validation in `subscribePersistent`:

```swift
        let key = SubscriptionKey(stream: target, group: group)
        if groupSettings[key] == nil {
            guard !requireExplicitGroups else {
                throw EventStoreClientError.subscriptionGroupNotFound(stream: target, group: group)
            }
            try await ensurePersistentSubscription(stream: target, group: group, settings: .init())
        }
        // `ensure` always creates the session alongside the group.
        return subscriptions[key]!
```

4. Add:

```swift
    public func ensurePersistentSubscription(
        stream target: String, group: String, settings: PersistentSubscriptionSettings
    ) async throws {
        try validateSubscriptionTarget(target)
        let key = SubscriptionKey(stream: target, group: group)
        guard groupSettings[key] == nil else { return }
        groupSettings[key] = settings

        let session = InMemorySubscriptionSession()
        subscriptions[key] = session
        // `.start`: replay everything already stored, in commit order, before live
        // tail delivery — makes "seed events, then subscribe" tests deterministic.
        // `.end`: only events appended from now on.
        if settings.startFrom == .start {
            for stored in matchingStoredEvents(for: target) {
                session.deliver(stored)
            }
        }
    }

    public func deletePersistentSubscription(stream target: String, group: String) async throws {
        let key = SubscriptionKey(stream: target, group: group)
        groupSettings.removeValue(forKey: key)
        subscriptions.removeValue(forKey: key)?
            .end(throwing: EventStoreClientError.subscriptionGroupNotFound(stream: target, group: group))
    }

    /// Test helper: whether the group currently exists.
    public func persistentSubscriptionExists(stream: String, group: String) -> Bool {
        groupSettings[SubscriptionKey(stream: stream, group: group)] != nil
    }
```

5. In `InMemorySubscriptionSession` add:

```swift
    func end(throwing error: any Error) {
        continuation.finish(throwing: error)
    }
```

Remove the old "Deliberate design choice" comment from `subscribePersistent` (it moved into `ensure`).

- [ ] **Step 5: Live implementation**

In `LiveEventStoreClient`:

```swift
    public func subscribePersistent(stream: String, group: String) async throws -> any PersistentSubscriptionSession {
        if let category = CategoryProjectionStream.category(forStream: stream), category.contains("-") {
            // (existing comment)
            throw EventStoreClientError.unroutableCategory(stream: stream)
        }
        do {
            let subscription = try await client.persistentSubscriptions(stream: stream, group: group).subscribe()
            return LiveSubscriptionSession(subscription: subscription, stream: stream, group: group)
        } catch {
            throw Self.mapMissingGroup(error, stream: stream, group: group)
        }
    }

    public func ensurePersistentSubscription(
        stream: String, group: String, settings: PersistentSubscriptionSettings
    ) async throws {
        do {
            try await client.persistentSubscriptions(stream: stream, group: group).create {
                $0.settings.resolveLink = settings.resolveLink
                switch settings.startFrom {
                case .start: $0.revision = .start
                case .end: $0.revision = .end
                }
            }
        } catch {
            // Only already-exists is the steady state (a group created by a prior
            // process start or by the application itself); everything else —
            // connection, auth — must reach the caller.
            guard case .resourceAlreadyExists = error else { throw error }
        }
    }

    public func deletePersistentSubscription(stream: String, group: String) async throws {
        do {
            try await client.persistentSubscriptions(stream: stream, group: group).delete()
        } catch {
            guard case .resourceNotFound = error else { throw error }
        }
    }

    /// KurrentDB answers a subscribe to a group that does not exist with NotFound
    /// ("Subscription group … does not exist"), which swift-kurrentdb maps to
    /// `.resourceNotFound` — same detection as `ContextForwarder.isMissingGroup`.
    static func mapMissingGroup(_ error: any Error, stream: String, group: String) -> any Error {
        if let kurrent = error as? KurrentError, case .resourceNotFound = kurrent {
            return EventStoreClientError.subscriptionGroupNotFound(stream: stream, group: group)
        }
        return error
    }
```

In `LiveSubscriptionSession.init`, add `stream: String, group: String` parameters and change the bridge's catch to:

```swift
            } catch {
                continuation.finish(throwing: LiveEventStoreClient.mapMissingGroup(error, stream: stream, group: group))
            }
```

If `create`'s closure parameter does not expose `revision` exactly as in `ContextForwarder.ensureSubscription` (Sources/ContextForwarder/ContextForwarder.swift:104-125), copy that function's form verbatim — it compiles against the pinned swift-kurrentdb.

- [ ] **Step 6: Run tests**

Run: `swift build && swift test --filter "InMemorySubscriptionGroupTests|InMemoryPersistentSubscriptionTests|InMemoryEventStoreClientTests"`
Expected: all PASS (existing in-memory suites unaffected).

- [ ] **Step 7: Commit**

```bash
git add Sources/KurrentSupport/Adapter/EventStoreClient.swift Sources/KurrentSupport/Adapter/LiveEventStoreClient.swift Sources/KurrentSupportInMemory/InMemoryEventStoreClient.swift Tests/KurrentSupportInMemoryTests/InMemorySubscriptionGroupTests.swift
git commit -m "feat(kurrent): EventStoreClient ensures/deletes persistent subscription groups; typed group-missing error

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Runners ensure and recreate their subscription group

**Files:**
- Modify: `Sources/KurrentSupport/Adapter/KurrentProjection.swift`, `Sources/PostgresSupport/KurrentProjection+PostgresConvenience.swift`
- Test: `Tests/KurrentSupportInMemoryTests/RunnerSubscriptionSetupTests.swift` (create)

**Interfaces:**
- Consumes: Task 6 API.
- Produces:

```swift
extension KurrentProjection {
    public enum SubscriptionSetup: Sendable {
        case ensure(PersistentSubscriptionSettings)
        case manual
    }
}
// Both runners, every init (designated + KurrentDBClient convenience + Postgres convenience):
//   subscriptionSetup: KurrentProjection.SubscriptionSetup = .ensure(.init())
// inserted after `retryPolicy:` and before `logger:`.
```

- [ ] **Step 1: Failing tests**

```swift
// Tests/KurrentSupportInMemoryTests/RunnerSubscriptionSetupTests.swift
import Testing
import Foundation
import Synchronization
import KurrentDB
import KurrentSupport
import KurrentSupportInMemory

private struct Ping: Codable, Sendable { let n: Int }

private func append(_ client: InMemoryEventStoreClient, _ n: Int) async throws {
    _ = try await client.append(
        events: [EventData(eventType: "Ping", model: Ping(n: n))],
        toStream: "Ping-\(n)", category: "Ping", expectedRevision: .noStream
    )
}

private func waitUntil(timeout: Duration = .seconds(2), _ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("condition not met within \(timeout)")
}

private func makeRunner(
    _ client: InMemoryEventStoreClient,
    setup: KurrentProjection.SubscriptionSetup = .ensure(.init()),
    into seen: Mutex<[Int]>
) -> KurrentProjection.PersistentSubscriptionRunner {
    KurrentProjection.PersistentSubscriptionRunner(
        client: client, stream: "$ce-Ping", groupName: "g", subscriptionSetup: setup
    )
    .register(
        extractInput: { try? $0.decode(to: Ping.self)?.n },
        execute: { n in seen.withLock { $0.append(n) } }
    )
}

@Suite("Runner subscription setup")
struct RunnerSubscriptionSetupTests {

    @Test(".ensure (default) creates a missing group from the start and consumes history")
    func ensureCreatesGroup() async throws {
        let client = InMemoryEventStoreClient(requireExplicitGroups: true)
        try await append(client, 1)
        let seen = Mutex<[Int]>([])
        let run = Task { try await makeRunner(client, into: seen).run() }
        try await waitUntil { seen.withLock { $0 } == [1] }
        run.cancel()
        #expect(await client.persistentSubscriptionExists(stream: "$ce-Ping", group: "g"))
    }

    @Test(".ensure(startFrom: .end) does not replay history")
    func ensureFromEnd() async throws {
        let client = InMemoryEventStoreClient(requireExplicitGroups: true)
        try await append(client, 1)
        let seen = Mutex<[Int]>([])
        let run = Task { try await makeRunner(client, setup: .ensure(.init(startFrom: .end)), into: seen).run() }
        try await waitUntil { await client.persistentSubscriptionExists(stream: "$ce-Ping", group: "g") }
        try await append(client, 2)
        try await waitUntil { !seen.withLock { $0 }.isEmpty }
        run.cancel()
        #expect(seen.withLock { $0 } == [2])
    }

    @Test("Group deleted mid-run: run throws subscriptionGroupNotFound, group is recreated, a rerun resumes from the start")
    func recreatesDeletedGroup() async throws {
        let client = InMemoryEventStoreClient(requireExplicitGroups: true)
        try await append(client, 1)
        let seen = Mutex<[Int]>([])
        let runner = makeRunner(client, into: seen)

        let first = Task { try await runner.run() }
        try await waitUntil { seen.withLock { $0 } == [1] }
        try await client.deletePersistentSubscription(stream: "$ce-Ping", group: "g")

        await #expect(throws: EventStoreClientError.subscriptionGroupNotFound(stream: "$ce-Ping", group: "g")) {
            try await first.value
        }
        #expect(await client.persistentSubscriptionExists(stream: "$ce-Ping", group: "g"))

        let second = Task { try await runner.run() }
        try await append(client, 2)
        try await waitUntil { seen.withLock { $0 }.contains(2) }
        second.cancel()
        // Replayed from the start after recreation: 1 is seen again, then 2.
        #expect(seen.withLock { $0 } == [1, 1, 2])
    }

    @Test(".manual keeps the old behavior: a missing group is an error and is not created")
    func manualDoesNotCreate() async throws {
        let client = InMemoryEventStoreClient(requireExplicitGroups: true)
        let seen = Mutex<[Int]>([])
        await #expect(throws: EventStoreClientError.subscriptionGroupNotFound(stream: "$ce-Ping", group: "g")) {
            try await makeRunner(client, setup: .manual, into: seen).run()
        }
        #expect(await client.persistentSubscriptionExists(stream: "$ce-Ping", group: "g") == false)
    }

    @Test("TransactionalSubscriptionRunner also ensures its group")
    func transactionalEnsures() async throws {
        let client = InMemoryEventStoreClient(requireExplicitGroups: true)
        let runner = KurrentProjection.TransactionalSubscriptionRunner(
            client: client, transactionProvider: NoopProvider(), stream: "$ce-Ping", groupName: "g"
        )
        let run = Task { try await runner.run() }
        try await waitUntil { await client.persistentSubscriptionExists(stream: "$ce-Ping", group: "g") }
        run.cancel()
    }
}

struct NoopProvider: TransactionProvider {
    typealias Transaction = Int
    func withTransaction<Result: Sendable>(_ body: (Int) async throws -> Result) async throws -> Result {
        try await body(0)
    }
}
```

Add `"EventSourcing"` is already a dependency of `KurrentSupportInMemoryTests` (for `TransactionProvider`); import it: add `import EventSourcing` at the top.

- [ ] **Step 2: Run, expect failure**

Run: `swift test --filter RunnerSubscriptionSetupTests`
Expected: compile error — `subscriptionSetup:` unknown.

- [ ] **Step 3: Implement `SubscriptionSetup` and the shared run prologue**

In `KurrentProjection` (next to `RunnerStopped`):

```swift
    /// How a runner treats its persistent subscription group.
    public enum SubscriptionSetup: Sendable {
        /// Create the group before subscribing if it doesn't exist, and recreate it
        /// when it disappears (KurrentDB recreated, group deleted). On disappearance
        /// `run()` recreates the group and then throws
        /// `EventStoreClientError.subscriptionGroupNotFound` so the caller's restart
        /// (ServiceGroup, etc.) resubscribes. With `startFrom: .start` the recreated
        /// group replays everything; the revision cursor makes that a no-op.
        case ensure(PersistentSubscriptionSettings)
        /// The caller creates and maintains the group (behavior before 1.4.0-beta.12).
        case manual
    }

    /// Shared by both runners: ensure the group, run `consume`, and recreate the group
    /// if it went missing.
    static func withSubscriptionGroup(
        client: any EventStoreClient,
        stream: String,
        group: String,
        setup: SubscriptionSetup,
        logger: Logger,
        consume: () async throws -> Void
    ) async throws {
        guard case let .ensure(settings) = setup else {
            try await consume()
            return
        }
        try await client.ensurePersistentSubscription(stream: stream, group: group, settings: settings)
        do {
            try await consume()
        } catch let error as EventStoreClientError {
            guard case .subscriptionGroupNotFound = error else { throw error }
            logger.warning("\(stream)/\(group): subscription group is missing — recreating it (startFrom: \(settings.startFrom))")
            try await client.ensurePersistentSubscription(stream: stream, group: group, settings: settings)
            throw error
        }
    }
```

- [ ] **Step 4: Wire into `PersistentSubscriptionRunner`**

Add `private let subscriptionSetup: SubscriptionSetup`; add the `subscriptionSetup: SubscriptionSetup = .ensure(.init())` parameter (after `retryPolicy:`) to the designated init and the `KurrentDBClient` convenience init, assigning/forwarding it. Rewrite `run()`:

```swift
        public func run() async throws {
            try await KurrentProjection.withSubscriptionGroup(
                client: client, stream: stream, group: groupName,
                setup: subscriptionSetup, logger: logger
            ) {
                let subscription = try await client.subscribePersistent(stream: stream, group: groupName)
                for try await delivery in subscription.events {
                    if Task.isCancelled { return }
                    do {
                        try await dispatch(record: delivery.event)
                        try await subscription.ack([delivery])
                    } catch {
                        try await handleFailure(error: error, delivery: delivery, subscription: subscription)
                    }
                }
            }
        }
```

Extend its doc comment's "Returns when…" paragraph with: "With the default `.ensure` setup the group is created first and recreated if it goes missing — see ``KurrentProjection/SubscriptionSetup``." Replace the type-level "System projection streams" doc section's manual `create { resolveLink = true }` example with a note that `.ensure` sets `resolveLink` by default and the snippet applies only to `.manual`.

- [ ] **Step 5: Wire into `TransactionalSubscriptionRunner`**

Same property + parameter on both inits. Rewrite `run()`:

```swift
        public func run() async throws {
            do {
                try await KurrentProjection.withSubscriptionGroup(
                    client: client, stream: stream, group: groupName,
                    setup: subscriptionSetup, logger: logger
                ) {
                    let subscription = try await client.subscribePersistent(stream: stream, group: groupName)
                    for try await delivery in subscription.events {
                        if Task.isCancelled { return }
                        do {
                            try await transactionProvider.withTransaction { tx in
                                try await self.dispatch(record: delivery.event, transaction: tx)
                            }
                            try await subscription.ack([delivery])
                        } catch {
                            try await handleFailure(error: error, delivery: delivery, subscription: subscription)
                        }
                    }
                }
            } catch is CancellationError {
                return
            }
        }
```

- [ ] **Step 6: Postgres convenience inits**

In `KurrentProjection+PostgresConvenience.swift`, add `subscriptionSetup: KurrentProjection.SubscriptionSetup = .ensure(.init()),` after `retryPolicy:` in both convenience inits and forward `subscriptionSetup: subscriptionSetup` to `self.init(...)`.

- [ ] **Step 7: Run tests**

Run: `swift build && swift test --filter "RunnerSubscriptionSetupTests|InMemoryPersistentSubscriptionTests|KurrentSupportUnitTests"`
Expected: all PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/KurrentSupport/Adapter/KurrentProjection.swift Sources/PostgresSupport/KurrentProjection+PostgresConvenience.swift Tests/KurrentSupportInMemoryTests/RunnerSubscriptionSetupTests.swift
git commit -m "feat(projection): runners ensure their subscription group and recreate it when it goes missing

Default .ensure(startFrom: .start, resolveLink: true); .manual keeps the old behavior.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Transactional runner dispatches projectors sequentially

**Files:**
- Modify: `Sources/KurrentSupport/Adapter/KurrentProjection.swift` (`TransactionalSubscriptionRunner.dispatch`)
- Test: `Tests/KurrentSupportInMemoryTests/TransactionalSequentialDispatchTests.swift` (create)

**Interfaces:**
- Consumes: Task 7 (`NoopProvider` lives in `RunnerSubscriptionSetupTests.swift`, same test target, internal).

- [ ] **Step 1: Failing test**

```swift
// Tests/KurrentSupportInMemoryTests/TransactionalSequentialDispatchTests.swift
import Testing
import Foundation
import Synchronization
import KurrentDB
import DDDCore
import EventSourcing
import ReadModelPersistence
import KurrentSupport
import KurrentSupportInMemory

private struct Placed: DomainEvent, Codable, Sendable {
    typealias Metadata = Never
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
    var metadata: Never? = nil
}

private struct PlacedMapper: EventTypeMapper {
    func mapping(eventData: any RecordedEventLike) throws -> (any DomainEvent)? {
        eventData.eventType == "Placed" ? try eventData.decode(to: Placed.self) : nil
    }
}

private struct SeqModel: ReadModel, Codable, Sendable { let id: String }
private struct SeqInput: CQRSProjectorInput, Sendable { let id: String }

private struct SeqProjector: EventSourcingProjector, Sendable {
    typealias Input = SeqInput
    typealias ReadModelType = SeqModel
    typealias Store = KurrentStorageCoordinator<SeqProjector, CustomMetadata>
    static var categoryRule: StreamCategoryRule { .custom("Seq") }
    let store: KurrentStorageCoordinator<SeqProjector, CustomMetadata>
    func apply(readModel: inout SeqModel, events: [any DomainEvent]) throws {}
    func buildReadModel(input: SeqInput) throws -> SeqModel? { SeqModel(id: input.id) }
}

/// Records fetch/save calls; label "A" sleeps in fetch so a parallel dispatch would interleave.
private struct RecordingStore: TransactionalReadModelStore {
    typealias Model = SeqModel
    typealias Transaction = Int
    let label: String
    let log: Mutex<[String]>
    let failOnSave: Bool

    func fetch(byId id: String, in transaction: Int) async throws -> StoredReadModel<SeqModel>? {
        log.withLock { $0.append("\(label).fetch") }
        if label == "A" { try await Task.sleep(for: .milliseconds(50)) }
        return nil
    }
    func save(readModel: SeqModel, revision: UInt64, in transaction: Int) async throws {
        log.withLock { $0.append("\(label).save") }
        if failOnSave { struct Boom: Error {}; throw Boom() }
    }
}

@Suite("TransactionalSubscriptionRunner — sequential dispatch")
struct TransactionalSequentialDispatchTests {

    private func run(failA: Bool) async throws -> [String] {
        let client = InMemoryEventStoreClient()
        let coordinator = KurrentStorageCoordinator<SeqProjector, CustomMetadata>(client: client, eventMapper: PlacedMapper())
        _ = try await coordinator.append(events: [Placed(aggregateRootId: "1")], byId: "1", version: nil, metadata: nil)

        let log = Mutex<[String]>([])
        let projector = SeqProjector(store: coordinator)
        let extract: @Sendable (any RecordedEventLike) -> SeqInput? = { _ in SeqInput(id: "1") }
        let runner = KurrentProjection.TransactionalSubscriptionRunner(
            client: client, transactionProvider: NoopProvider(), stream: "$ce-Seq", groupName: "g",
            retryPolicy: KurrentProjection.MaxRetriesPolicy(max: 0)
        )
        .register(projector: projector, storeFactory: { _ in RecordingStore(label: "A", log: log, failOnSave: failA) }, extractInput: extract)
        .register(projector: projector, storeFactory: { _ in RecordingStore(label: "B", log: log, failOnSave: false) }, extractInput: extract)

        let task = Task { try await runner.run() }
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline, log.withLock({ $0.count }) < (failA ? 2 : 4) {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(100)) // let any (wrong) parallel sibling show up
        task.cancel()
        return log.withLock { $0 }
    }

    @Test("Projectors run one after another in registration order")
    func registrationOrder() async throws {
        #expect(try await run(failA: false) == ["A.fetch", "A.save", "B.fetch", "B.save"])
    }

    @Test("A failing projector stops the ones registered after it")
    func stopsAfterFailure() async throws {
        #expect(try await run(failA: true) == ["A.fetch", "A.save"])
    }
}
```

`Mutex` is non-copyable, so `RecordingStore` can't hold it by value — wrap the log in a
`final class Log: Sendable { let entries = Mutex<[String]>([]) }` and store `let log: Log`
(use `log.entries.withLock`) in both the store and the test's `run(failA:)`.

- [ ] **Step 2: Run, expect failure**

Run: `swift test --filter TransactionalSequentialDispatchTests`
Expected: `registrationOrder` FAILS (`["A.fetch", "B.fetch", ...]`), `stopsAfterFailure` FAILS (B.fetch present).

- [ ] **Step 3: Implement**

Replace `TransactionalSubscriptionRunner.dispatch(record:transaction:)`:

```swift
        /// Dispatch a single recorded event to every registered projector, one after
        /// another in registration order, within the supplied transaction. Sequential
        /// on purpose: all projectors share the transaction's single connection.
        /// The first throw stops the rest and bubbles to `withTransaction`, which
        /// rolls back.
        internal func dispatch(record: any RecordedEventLike, transaction tx: Provider.Transaction) async throws {
            let snapshot = _registrations.withLock { $0 }
            for registration in snapshot {
                try await registration.dispatch(record, tx)
            }
        }
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter "TransactionalSequentialDispatchTests|RunnerSubscriptionSetupTests|KurrentSupportUnitTests"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/KurrentSupport/Adapter/KurrentProjection.swift Tests/KurrentSupportInMemoryTests/TransactionalSequentialDispatchTests.swift
git commit -m "fix(projection): TransactionalSubscriptionRunner dispatches projectors sequentially on the shared connection

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: `KurrentProjection.rebuild`

**Files:**
- Create: `Sources/KurrentSupport/Adapter/KurrentProjection+Rebuild.swift`
- Modify: `Package.swift` — add `"ReadModelPersistence"` to the `KurrentSupport` target's dependencies if it is not already importable there (`KurrentProjection.swift` already `import ReadModelPersistence`; check `swift build` first).
- Test: `Tests/KurrentSupportInMemoryTests/RebuildTests.swift` (create)

**Interfaces:**
- Consumes: `ReadModelSnapshotPurging` (Task 5), ensure/delete (Task 6), `readModelTypeName` (Task 1).
- Produces:

```swift
extension KurrentProjection {
    public static func rebuild(
        readModels: [any ReadModel.Type],
        snapshots: any ReadModelSnapshotPurging,
        eventStore: any EventStoreClient,
        stream: String,
        group: String,
        settings: PersistentSubscriptionSettings = .init(startFrom: .start),
        logger: Logger = Logger(label: "KurrentProjection.rebuild")
    ) async throws
    public static func rebuild(readModels:snapshots:client: KurrentDBClient, stream:group:settings:logger:) async throws
}
```

- [ ] **Step 1: Failing tests**

```swift
// Tests/KurrentSupportInMemoryTests/RebuildTests.swift
import Testing
import Foundation
import KurrentDB
import EventSourcing
import ReadModelPersistence
import KurrentSupport
import KurrentSupportInMemory

private struct Summary: ReadModel, Sendable { let id: String }
private struct Ping: Codable, Sendable { let n: Int }

@Suite("KurrentProjection.rebuild")
struct RebuildTests {

    private func seeded() async throws -> (InMemoryEventStoreClient, InMemoryReadModelStore<Summary>) {
        let client = InMemoryEventStoreClient(requireExplicitGroups: true)
        _ = try await client.append(
            events: [EventData(eventType: "Ping", model: Ping(n: 1))],
            toStream: "Ping-1", category: "Ping", expectedRevision: .noStream
        )
        try await client.ensurePersistentSubscription(stream: "$ce-Ping", group: "g", settings: .init(startFrom: .end))
        let store = InMemoryReadModelStore<Summary>()
        try await store.save(readModel: Summary(id: "1"), revision: 0)
        return (client, store)
    }

    @Test("Purges snapshots and recreates the group from the start")
    func purgesAndResets() async throws {
        let (client, store) = try await seeded()

        try await KurrentProjection.rebuild(
            readModels: [Summary.self], snapshots: store,
            eventStore: client, stream: "$ce-Ping", group: "g"
        )

        #expect(try await store.fetch(byId: "1") == nil)
        let session = try await client.subscribePersistent(stream: "$ce-Ping", group: "g")
        var replayed: Int?
        for try await delivery in session.events {
            replayed = try delivery.event.decode(to: Ping.self)?.n
            break
        }
        #expect(replayed == 1) // the old group started at .end; the rebuilt one replays history
    }

    @Test("Rebuilding twice in a row (a re-run after a partial failure) succeeds")
    func idempotent() async throws {
        let (client, store) = try await seeded()
        for _ in 0..<2 {
            try await KurrentProjection.rebuild(
                readModels: [Summary.self], snapshots: store,
                eventStore: client, stream: "$ce-Ping", group: "g"
            )
        }
        #expect(await client.persistentSubscriptionExists(stream: "$ce-Ping", group: "g"))
    }

    @Test("Works when the group never existed")
    func missingGroup() async throws {
        let client = InMemoryEventStoreClient(requireExplicitGroups: true)
        try await KurrentProjection.rebuild(
            readModels: [Summary.self], snapshots: InMemoryReadModelStore<Summary>(),
            eventStore: client, stream: "$ce-Ping", group: "g"
        )
        #expect(await client.persistentSubscriptionExists(stream: "$ce-Ping", group: "g"))
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `swift test --filter RebuildTests`
Expected: compile error — `rebuild` missing.

- [ ] **Step 3: Implement**

```swift
// Sources/KurrentSupport/Adapter/KurrentProjection+Rebuild.swift
import KurrentDB
import Logging
import EventSourcing
import ReadModelPersistence

extension KurrentProjection {

    /// Rebuilds read models from scratch: deletes the subscription group, purges the
    /// listed read models' snapshots, and recreates the group (from the start by default),
    /// so the next runner start replays every event.
    ///
    /// Use it after any change that makes stored snapshots unreadable or wrong — a
    /// field made required, a type change, a new `readModelTypeName`, a different
    /// snapshot write mode or table.
    ///
    /// **Stop every consumer of `group` first**, run this, then deploy the new
    /// version. Deleting the group first cuts off a consumer that was missed, but it
    /// may still be running the old schema.
    ///
    /// Every step is idempotent — re-run after a partial failure. Read models sharing
    /// the group but not listed are replayed too; their stored revisions make that a no-op.
    public static func rebuild(
        readModels: [any ReadModel.Type],
        snapshots: any ReadModelSnapshotPurging,
        eventStore: any EventStoreClient,
        stream: String,
        group: String,
        settings: PersistentSubscriptionSettings = .init(startFrom: .start),
        logger: Logger = Logger(label: "KurrentProjection.rebuild")
    ) async throws {
        let typeNames = readModels.map { $0.readModelTypeName }
        logger.notice("rebuild \(stream)/\(group): deleting group, purging \(typeNames)")
        try await eventStore.deletePersistentSubscription(stream: stream, group: group)
        try await snapshots.purgeSnapshots(ofTypes: typeNames)
        try await eventStore.ensurePersistentSubscription(stream: stream, group: group, settings: settings)
        logger.notice("rebuild \(stream)/\(group): group recreated (startFrom: \(settings.startFrom)); restart consumers to replay")
    }

    /// Convenience for a real KurrentDB connection.
    public static func rebuild(
        readModels: [any ReadModel.Type],
        snapshots: any ReadModelSnapshotPurging,
        client: KurrentDBClient,
        stream: String,
        group: String,
        settings: PersistentSubscriptionSettings = .init(startFrom: .start),
        logger: Logger = Logger(label: "KurrentProjection.rebuild")
    ) async throws {
        try await rebuild(
            readModels: readModels, snapshots: snapshots,
            eventStore: LiveEventStoreClient(client: client),
            stream: stream, group: group, settings: settings, logger: logger
        )
    }
}
```

If `KurrentSupport` fails to import `Logging`/`ReadModelPersistence`, add `.product(name: "Logging", package: "swift-log")` / `"ReadModelPersistence"` to its target dependencies in `Package.swift` (it already imports both in `KurrentProjection.swift`, so this should not be needed).

- [ ] **Step 4: Run tests**

Run: `swift test --filter RebuildTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/KurrentSupport/Adapter/KurrentProjection+Rebuild.swift Tests/KurrentSupportInMemoryTests/RebuildTests.swift Package.swift
git commit -m "feat(projection): KurrentProjection.rebuild — delete group, purge snapshots, recreate from the start

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Integration tests against throwaway KurrentDB + Postgres

**Files:**
- Create: `Tests/KurrentSupportIntegrationTests/SubscriptionGroupLifecycleIntegrationTests.swift`
- Modify: `Tests/KurrentSupportIntegrationTests/KurrentProjectionTransactionalRunnerIntegrationTests.swift` (switch to the pooled client so it can run against the throwaway container)

**Interfaces:**
- Consumes: Tasks 4–9.

- [ ] **Step 1: Make the transactional integration suite container-safe**

In `KurrentProjectionTransactionalRunnerIntegrationTests.swift`, wrap each test body that does `let kdb = KurrentDBClient.makeIntegrationTestClient()` in `try await KurrentDBClient.withPooledIntegrationTestClient { kdb in ... }` (remove the `let kdb = ...` line). Leave the explicit `.create { resolveLink = true }` calls in place — they now double as the "pre-created group still works with default `.ensure`" check (Review Focus 5).

- [ ] **Step 2: Write lifecycle + rebuild integration tests**

```swift
// Tests/KurrentSupportIntegrationTests/SubscriptionGroupLifecycleIntegrationTests.swift
import Testing
import Foundation
import KurrentDB
import KurrentSupport
import PostgresSupport
import EventSourcing
import ReadModelPersistence
import ReadModelPersistencePostgres
import PostgresNIO
import TestUtility
import DDDCore

private struct LifecycleEvent: DomainEvent, Codable, Sendable {
    typealias Metadata = Never
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
    var metadata: Never? = nil
    var label: String
}

private struct LifecycleMapper: EventTypeMapper {
    func mapping(eventData: any RecordedEventLike) throws -> (any DomainEvent)? {
        eventData.eventType == "LifecycleEvent" ? try eventData.decode(to: LifecycleEvent.self) : nil
    }
}

private struct LifecycleModel: ReadModel, Codable, Sendable {
    static var readModelTypeName: String { "LifecycleModel.test" }
    let id: String
    var label: String = ""
}

private struct LifecycleInput: CQRSProjectorInput, Sendable { let id: String }

private struct LifecycleProjector: EventSourcingProjector, Sendable {
    typealias Input = LifecycleInput
    typealias ReadModelType = LifecycleModel
    typealias Store = KurrentStorageCoordinator<LifecycleProjector, CustomMetadata>
    static var categoryRule: StreamCategoryRule { .custom("Lifecycle") }
    let store: KurrentStorageCoordinator<LifecycleProjector, CustomMetadata>
    func apply(readModel: inout LifecycleModel, events: [any DomainEvent]) throws {
        for case let e as LifecycleEvent in events { readModel.label = e.label }
    }
    func buildReadModel(input: LifecycleInput) throws -> LifecycleModel? { LifecycleModel(id: input.id) }
}

private func pgClient() -> PostgresClient {
    let env = ProcessInfo.processInfo.environment
    return PostgresClient(configuration: .init(
        host: env["PG_HOST"] ?? "localhost",
        port: Int(env["PG_PORT"] ?? "5432") ?? 5432,
        username: env["PG_USER"] ?? "postgres",
        password: env["PG_PASSWORD"] ?? "postgres",
        database: env["PG_DATABASE"] ?? "postgres",
        tls: .disable
    ))
}

@Suite("Subscription group lifecycle — integration", .serialized)
struct SubscriptionGroupLifecycleIntegrationTests {

    @Test("Live: ensure tolerates an existing group, delete tolerates a missing one, subscribe maps NotFound")
    func liveLifecycle() async throws {
        try await KurrentDBClient.withPooledIntegrationTestClient { kdb in
            let live = LiveEventStoreClient(client: kdb)
            let stream = "$ce-Lifecycle"
            let group = "lifecycle-\(UUID().uuidString.prefix(8))"

            try await live.ensurePersistentSubscription(stream: stream, group: group, settings: .init())
            try await live.ensurePersistentSubscription(stream: stream, group: group, settings: .init())
            try await live.deletePersistentSubscription(stream: stream, group: group)
            try await live.deletePersistentSubscription(stream: stream, group: group)

            await #expect(throws: EventStoreClientError.subscriptionGroupNotFound(stream: stream, group: group)) {
                let session = try await live.subscribePersistent(stream: stream, group: group)
                for try await _ in session.events { break }
            }
        }
    }

    @Test("End to end: runner fills the monotonic table, rebuild purges and resets, rerun refills it")
    func rebuildEndToEnd() async throws {
        let pg = pgClient()
        try await withThrowingTaskGroup(of: Void.self) { tg in
            tg.addTask { await pg.run() }
            try await KurrentDBClient.withPooledIntegrationTestClient { kdb in
                try await PostgresReadModelMigration.createTable(on: pg)
                let stream = "$ce-Lifecycle"
                let group = "lifecycle-rebuild-\(UUID().uuidString.prefix(8))"
                let id = UUID().uuidString
                let coordinator = KurrentStorageCoordinator<LifecycleProjector, CustomMetadata>(client: kdb, eventMapper: LifecycleMapper())
                _ = try await coordinator.append(events: [LifecycleEvent(aggregateRootId: id, label: "v1")], byId: id, version: nil, metadata: nil)

                func runOnce() async throws -> String? {
                    let runner = KurrentProjection.TransactionalSubscriptionRunner(
                        client: kdb, pgClient: pg, stream: stream, groupName: group
                    )
                    .register(
                        projector: LifecycleProjector(store: coordinator),
                        storeFactory: { _ in PostgresTransactionalReadModelStore<LifecycleModel>() },
                        extractInput: { record in
                            record.streamName.hasPrefix("Lifecycle-")
                                ? LifecycleInput(id: String(record.streamName.dropFirst("Lifecycle-".count))) : nil
                        }
                    )
                    let task = Task { try await runner.run() }
                    defer { task.cancel() }
                    let store = PostgresJSONReadModelStore<LifecycleModel>(client: pg)
                    let deadline = ContinuousClock.now + .seconds(10)
                    while ContinuousClock.now < deadline {
                        if let label = try await store.fetch(byId: id)?.readModel.label { return label }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    return nil
                }

                #expect(try await runOnce() == "v1")

                try await KurrentProjection.rebuild(
                    readModels: [LifecycleModel.self],
                    snapshots: PostgresReadModelSnapshots(client: pg),
                    client: kdb, stream: stream, group: group
                )
                #expect(try await PostgresJSONReadModelStore<LifecycleModel>(client: pg).fetch(byId: id) == nil)

                #expect(try await runOnce() == "v1")
                try await LiveEventStoreClient(client: kdb).deletePersistentSubscription(stream: stream, group: group)
            }
            tg.cancelAll()
        }
    }
}
```

- [ ] **Step 3: Run the integration suites (containers up, env exported, gossip check done)**

Run: `swift test --filter "SubscriptionGroupLifecycleIntegrationTests|KurrentProjectionTransactionalRunnerIntegrationTests|ReadModelPersistencePostgresIntegrationTests"`
Expected: all PASS. If the live NotFound surfaces as some other `KurrentError` case, print it, update `LiveEventStoreClient.mapMissingGroup` to match the observed case, and note the observed case in its doc comment.

- [ ] **Step 4: Commit**

```bash
git add Tests/KurrentSupportIntegrationTests
git commit -m "test(projection): integration coverage for group lifecycle and rebuild (pooled client, throwaway containers)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Samples

**Files:**
- Modify: `samples/KurrentTransactionalProjectionDemo/Sources/main.swift:197-245`, `samples/PostgresReadModelDemo/Sources/main.swift`

- [ ] **Step 1: Transactional demo**

Delete the manual `kdbClient.persistentSubscriptions(stream:group:).create { ... }` block around line 206 (the runner's default `.ensure` now creates the group); replace it with a one-line comment: `// The runner creates the persistent subscription group itself (SubscriptionSetup.ensure, the default).` Keep `PostgresReadModelMigration.createTable(on: pgClient)` (now creates `read_model_snapshots_monotonic`). Any raw SQL in the demo that reads `read_model_snapshots` must read `read_model_snapshots_monotonic`: run `grep -n "read_model_snapshots" samples/KurrentTransactionalProjectionDemo/Sources/*.swift` and update each hit.

- [ ] **Step 2: PostgresReadModelDemo**

No API change required (defaults move to monotonic consistently for `createTable` and the store). Run `grep -n "read_model_snapshots" samples/PostgresReadModelDemo/Sources/*.swift` and update any raw table reference to `read_model_snapshots_monotonic`.

- [ ] **Step 3: Build both samples**

Run: `(cd samples/KurrentTransactionalProjectionDemo && swift build) && (cd samples/PostgresReadModelDemo && swift build)`
Expected: both build.

- [ ] **Step 4: Commit**

```bash
git add samples/KurrentTransactionalProjectionDemo samples/PostgresReadModelDemo
git commit -m "docs(samples): rely on runner-managed subscription groups and the monotonic snapshot table

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Documentation — DocC Getting Started, write modes, rebuild; README; site; CLAUDE.md

**Files:**
- Create: `Sources/ReadModelPersistencePostgres/ReadModelPersistencePostgres.docc/ReadModelPersistencePostgres.md`, `GettingStarted.md`, `SnapshotWriteModes.md`
- Create: `Sources/ReadModelPersistence/ReadModelPersistence.docc/ReadModelPersistence.md`, `SchemaEvolutionAndRebuilding.md`
- Modify: `README.md`, `docs/index.html` (v1.4 release card + Guides), `CLAUDE.md` (architecture)

- [ ] **Step 1: `ReadModelPersistencePostgres.docc/ReadModelPersistencePostgres.md`**

```markdown
# ``ReadModelPersistencePostgres``

Store read model snapshots in PostgreSQL as JSONB, written by a KurrentDB persistent subscription.

## Overview

Snapshots are a disposable projection cache: one row per `(id, type)` holding the read model as
JSONB plus the stream revision it was folded up to. Applications query the table with their own
SQL; recovery from any schema change is a rebuild, never a data migration.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:SnapshotWriteModes>

### Stores

- ``PostgresTransactionalReadModelStore``
- ``PostgresJSONReadModelStore``
- ``PostgresTransactionProvider``

### Schema and maintenance

- ``PostgresReadModelMigration``
- ``SnapshotWriteMode``
- ``PostgresReadModelSnapshots``
```

- [ ] **Step 2: `GettingStarted.md`**

Write the article with exactly these sections and code (code compiled against this branch — copy the shapes from `samples/KurrentTransactionalProjectionDemo` and Task 10's fixtures):

````markdown
# Getting Started with Postgres read models

Project KurrentDB events into a queryable Postgres table in five steps.

## 1. Create the snapshot table

Run once at startup — it is idempotent.

```swift
try await PostgresReadModelMigration.createTable(on: pgClient)
// creates read_model_snapshots_monotonic (the default .monotonic write mode)
```

## 2. Define the read model

```swift
struct OrderSummary: ReadModel, Codable, Sendable {
    // Stable stored name — survives a Swift rename. Optional; defaults to the type name.
    static var readModelTypeName: String { "OrderSummary" }

    let id: String
    var customerId: String = ""
    var totalAmount: Double = 0
    var note: String? = nil   // new fields: make them optional (see "Schema evolution")
}
```

## 3. Write the projector

Generate `OrderSummaryProjectorProtocol` from `projection-model.yaml` with `ModelGeneratorPlugin`,
then implement one `when` per listed event. Events not listed are skipped.

```swift
struct OrderSummaryProjector: OrderSummaryProjectorProtocol {
    typealias ReadModelType = OrderSummary
    typealias Input = OrderSummaryInput
    typealias Store = KurrentStorageCoordinator<OrderSummaryProjector, CustomMetadata>
    static var categoryRule: StreamCategoryRule { .custom("Order") }
    let store: Store

    func buildReadModel(input: Input) throws -> OrderSummary? { OrderSummary(id: input.id) }
    func when(readModel: inout OrderSummary, event: OrderCreated) throws { … }
    func when(readModel: inout OrderSummary, event: OrderAmountUpdated) throws { … }
}
```

## 4. Run the subscription runner

```swift
let runner = KurrentProjection.TransactionalSubscriptionRunner(
    client: kurrentClient,
    pgClient: pgClient,
    stream: "$ce-Order",
    groupName: "order-summary"
)
.register(
    projector: OrderSummaryProjector(store: coordinator),
    storeFactory: { _ in PostgresTransactionalReadModelStore<OrderSummary>() },
    extractInput: { record in
        record.streamName.hasPrefix("Order-")
            ? OrderSummaryInput(id: String(record.streamName.dropFirst("Order-".count))) : nil
    }
)
```

The runner creates the `order-summary` group if it is missing (from the start of the stream,
with `resolveLink` on) and recreates it if it disappears, then throws so your supervisor
restarts it. Run it under Swift Service Lifecycle's `ServiceGroup`, which restarts on failure.
Pass `subscriptionSetup: .manual` to manage the group yourself.

## 5. Query

```sql
SELECT data->>'customerId' AS customer, (data->>'totalAmount')::numeric AS total
FROM read_model_snapshots_monotonic
WHERE type = 'OrderSummary' AND data->>'customerId' = $1;
```

Indexes are yours to add in your own migrations (e.g. an expression index on
`(data->>'customerId') WHERE type = 'OrderSummary'`).

## Next

- <doc:SnapshotWriteModes> — why the default is `.monotonic`, and when to choose `.overwrite`.
- Schema changes and rebuilding: see the `ReadModelPersistence` article
  "Schema evolution and rebuilding" and ``KurrentProjection/rebuild(readModels:snapshots:client:stream:group:settings:logger:)``.
````

Replace each `…` in the article with a one-line body (e.g. `readModel.customerId = event.customerId`) — the article must contain no ellipses.

- [ ] **Step 3: `SnapshotWriteModes.md`**

```markdown
# Snapshot write modes

Choose what happens when two writes for the same read model race.

## Overview

| Mode | Table (default base) | On an existing row |
|---|---|---|
| ``SnapshotWriteMode/monotonic`` (default) | `read_model_snapshots_monotonic` | replaced only by a **strictly newer** revision |
| ``SnapshotWriteMode/overwrite`` | `read_model_snapshots` | always replaced |

### Why monotonic is the default

Two consumers can fold the same read model concurrently — several instances, or a nacked event
redelivered out of order. Consumer A folds to revision 6 and commits; consumer B, which stopped at
revision 5, commits afterwards. With `.overwrite` the snapshot rolls back to 5 until the stream
receives another event. With `.monotonic` B's write is skipped: every snapshot is a complete fold
up to its revision, so keeping the highest revision is always correct.

### When to choose overwrite

When a stream's revision can legitimately go backwards — a stream hard-deleted and recreated under
the same id starts again at revision 0, and `.monotonic` would skip every write for it.

### Separate tables

Each mode writes its own table, so switching never mixes rows written under different rules.
Switching modes (or the base `tableName`) leaves the new table empty — rebuild afterwards
(see ``PostgresReadModelSnapshots`` and `KurrentProjection.rebuild`). Pass the same
`tableName`/`writeMode` to `PostgresReadModelMigration.createTable`, every store, and
`PostgresReadModelSnapshots`.
```

- [ ] **Step 4: `ReadModelPersistence.docc/ReadModelPersistence.md`**

```markdown
# ``ReadModelPersistence``

Persist read model snapshots with the revision they were folded up to.

## Overview

A snapshot is a cache of a projection, never the source of truth: the event store is. Any
snapshot can be thrown away and rebuilt by replaying events, which is how schema changes are
handled.

## Topics

### Essentials

- <doc:SchemaEvolutionAndRebuilding>

### Stores

- ``ReadModelStore``
- ``TransactionalReadModelStore``
- ``InMemoryReadModelStore``
- ``StoredReadModel``

### Rebuilding

- ``ReadModelSnapshotPurging``
```

- [ ] **Step 5: `SchemaEvolutionAndRebuilding.md`**

````markdown
# Schema evolution and rebuilding

Change a read model's shape without leaving undecodable snapshots behind.

## No rebuild needed

- Adding an **optional** property (`var note: String? = nil`). Old snapshots decode with `nil`;
  the value fills in as the read model's stream receives new events — or rebuild to fill it now.

## Rebuild required

Old snapshots would fail to decode (and the runner would nack the event forever) or would be
silently orphaned after any of these:

- a property made required, or its type changed
- a different `readModelTypeName` (including renaming the Swift type when relying on the default)
- a different snapshot write mode or base table name
- a projector change that must be applied to history

## Procedure

1. Stop every consumer of the subscription group.
2. Run the rebuild:

   ```swift
   try await KurrentProjection.rebuild(
       readModels: [OrderSummary.self],
       snapshots: PostgresReadModelSnapshots(client: pgClient),
       client: kurrentClient,
       stream: "$ce-Order",
       group: "order-summary"
   )
   ```

3. Deploy the new version. The runner replays the stream from the start and writes fresh snapshots.

Every step is idempotent; re-run after a partial failure.

## Why purging alone is not enough

The subscription group's checkpoint is already past the existing events. After a purge alone,
only read models whose stream receives a new event are rebuilt; the rest stay missing. The rebuild
deletes and recreates the group from the start so every event is replayed. Read models sharing the
group that you did not list are replayed too — their stored revisions make that a no-op.
````

- [ ] **Step 6: README**

Add a `## Postgres read models` section after the existing projection/read-model material (find it with `grep -n "^## " README.md`): 3–4 sentences + the step-1 and step-4 code from Getting Started + a bullet list linking to the three DocC articles at `https://gradyzhuo.github.io/swift-ddd-kit/main/documentation/readmodelpersistencepostgres/gettingstarted`, `.../snapshotwritemodes`, and `.../readmodelpersistence/schemaevolutionandrebuilding` (verify the URL scheme against existing README links to the docs site and match it).

- [ ] **Step 7: Site**

In `docs/index.html`, inside `<article class="release" id="v1.4">`, add an item matching the existing item markup (bilingual `<span lang="en">`/`<span lang="zh-Hant">`) titled "Postgres read models, production-ready" / "Postgres read model 上線強化", listing: monotonic snapshots by default, runner-managed subscription groups, `KurrentProjection.rebuild`, stable `readModelTypeName`, generated `apply()` no longer aborts a fold. In the `#docs` Guides grid add a card "Getting Started: Postgres read models" / "快速上手：Postgres read model" linking to the Getting Started article URL from Step 6.

- [ ] **Step 8: CLAUDE.md**

Under "Key Protocols", add entries for `SnapshotWriteMode` (ReadModelPersistencePostgres), `ReadModelSnapshotPurging` (ReadModelPersistence), `KurrentProjection.SubscriptionSetup` and `KurrentProjection.rebuild` (KurrentSupport), and `ReadModel.readModelTypeName`; add `ProjectorGeneratorFixture` to the layer list as a test-only fixture. One or two lines each, matching the existing style.

- [ ] **Step 9: Verify docs build**

Run: `swift build && bash scripts/emit-symbol-graphs.sh . "$(mktemp -d)" 2>&1 | tail -5` — check the script's usage line first (`sed -n 1,30p scripts/emit-symbol-graphs.sh`) and pass arguments accordingly.
Expected: no missing-module error; then `xcrun docc convert Sources/ReadModelPersistencePostgres/ReadModelPersistencePostgres.docc --additional-symbol-graph-dir <graphs> --output-path "$(mktemp -d)"` reports no unresolved `<doc:>` links (warnings about `KurrentProjection` cross-module symbol links in plain code spans are fine; double-backtick symbol links must resolve).

- [ ] **Step 10: Commit**

```bash
git add Sources/ReadModelPersistence/ReadModelPersistence.docc Sources/ReadModelPersistencePostgres/ReadModelPersistencePostgres.docc README.md docs/index.html CLAUDE.md
git commit -m "docs(read-model): Getting Started for Postgres read models, write modes, schema evolution & rebuild

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: Full verification, PR, release

- [ ] **Step 1: Unit-level suites (no servers)**

Run: `swift build && swift test --filter "ReadModelPersistenceTests|DomainEventGeneratorTests|ProjectorGeneratorFixtureTests|KurrentSupportUnitTests|KurrentSupportInMemoryTests|EventSourcingTests|DDDKitUnitTests"`
Expected: all PASS.

- [ ] **Step 2: Integration suites (throwaway containers only)**

Run: `swift test --filter "ReadModelPersistencePostgresIntegrationTests|SubscriptionGroupLifecycleIntegrationTests|KurrentProjectionTransactionalRunnerIntegrationTests"`
Expected: all PASS. Then `docker rm -f ddd-kit-hardening-pg ddd-kit-hardening-kdb`.

- [ ] **Step 3: Sync and push**

```bash
git fetch origin
git rebase origin/main
git push --force-with-lease -u origin feat/pg-read-model-hardening
```

- [ ] **Step 4: Open the PR (base main)**

`gh pr create --base main --title "Postgres read model hardening: monotonic snapshots, self-healing groups, rebuild" --body-file <file>` with a body covering: the five problems (spec Context), what changed per area, **behavior changes** (default table `read_model_snapshots_monotonic`; runners create/recreate groups by default; generated `apply()` continues past unlisted events), how it was tested (unit + throwaway-container integration), link to the spec, ending with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.

- [ ] **Step 5: After merge — tag**

Only after the user confirms the merge: `git fetch origin && git tag 1.4.0-beta.12 origin/main && git push origin 1.4.0-beta.12`. Report the version to the user and to the NotificationContext session (`notificationcontext-29`).
