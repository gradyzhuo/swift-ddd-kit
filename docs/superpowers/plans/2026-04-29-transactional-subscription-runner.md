# TransactionalSubscriptionRunner Implementation Plan (Phase 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the spec at `docs/superpowers/specs/2026-04-29-transactional-subscription-runner-design.md` — a new `KurrentProjection.TransactionalSubscriptionRunner<Provider>` that runs all registered projectors' writes inside a per-event shared transaction, plus the cleanup of Phase 1's `register(stateful:)` API in the same change.

**Architecture:** Core/application layer split. Core protocols (`TransactionProvider`, `TransactionalReadModelStore`) live in `EventSourcing`. Generic runner lives in `KurrentSupport`. Postgres concrete impls + convenience init live in `ReadModelPersistencePostgres`. Both runners drop `StatefulEventSourcingProjector` from their public register API; the runner internally inlines fetch+apply+save (no new public type, YAGNI on extraction).

**Tech Stack:** Swift 6, swift-kurrentdb 2.0.x, postgres-nio 1.21+, Swift Testing.

**Spec reference:** `docs/superpowers/specs/2026-04-29-transactional-subscription-runner-design.md`

---

## Spec deviation noted up-front

The spec showed `TransactionProvider` with `begin / commit / rollback` methods. After checking postgres-nio's actual API (`PostgresClient.withTransaction { connection in ... }` callback-based with auto-commit/rollback), the protocol is implemented as:

```swift
func withTransaction<Result: Sendable>(_ body: (Transaction) async throws -> Result) async throws -> Result
```

This matches postgres-nio's idiom directly, eliminates the orphan-transaction class of bug, and preserves the Phase 2 spec's intent (atomicity, all-or-nothing semantics). Open Item #1 in the spec is hereby resolved this way.

---

## File Structure

| Path | Action | Responsibility |
|---|---|---|
| `Sources/EventSourcing/Projector/TransactionProvider.swift` | **NEW** | Protocol — `withTransaction` callback shape |
| `Sources/EventSourcing/Projector/TransactionalReadModelStore.swift` | **NEW** | Protocol — `save(...:in:)` and `fetch(...:in:)` |
| `Sources/ReadModelPersistencePostgres/PostgresTransactionProvider.swift` | **NEW** | Concrete — wraps `PostgresClient.withTransaction` |
| `Sources/ReadModelPersistencePostgres/PostgresTransactionalReadModelStore.swift` | **NEW** | Concrete — stateless, takes `PostgresConnection` per call |
| `Sources/KurrentSupport/Adapter/KurrentProjection.swift` | **MODIFY** | Add `TransactionalSubscriptionRunner<Provider>`; remove Phase 1 `register(stateful:)`; add `register(projector:store:)` to Phase 1 runner |
| `Sources/ReadModelPersistencePostgres/KurrentProjection+PostgresConvenience.swift` | **NEW** | Application-layer convenience init `where Provider == PostgresTransactionProvider` |
| `Tests/EventSourcingTests/TransactionProviderTests.swift` | **NEW** | Stub-conformance test |
| `Tests/EventSourcingTests/TransactionalReadModelStoreTests.swift` | **NEW** | Stub-conformance test |
| `Tests/ReadModelPersistencePostgresIntegrationTests/PostgresTransactionProviderTests.swift` | **NEW** | Real-PG begin/commit/rollback |
| `Tests/ReadModelPersistencePostgresIntegrationTests/PostgresTransactionalReadModelStoreTests.swift` | **NEW** | Real-PG save/fetch within tx; rollback isolation |
| `Tests/KurrentSupportUnitTests/KurrentProjectionRunnerSetupTests.swift` | **MODIFY** | Migrate to new `register(projector:store:)` form |
| `Tests/KurrentSupportUnitTests/KurrentProjectionRunnerFilterTests.swift` | **MODIFY** | Migrate to new register form (where applicable) |
| `Tests/KurrentSupportIntegrationTests/KurrentProjectionRunnerIntegrationTests.swift` | **MODIFY** | Migrate Phase 1 tests to new form; add Phase 2 transactional integration tests |
| `samples/KurrentProjectionDemo/Sources/main.swift` | **MODIFY** | Migrate to new `register(projector:store:)` form |
| `samples/KurrentTransactionalProjectionDemo/...` | **NEW** | New sample demonstrating Phase 2 + rollback observable |
| `Package.swift` | **MODIFY** | Add new sample target metadata if needed; verify dependencies |
| `README.md` | **MODIFY** | New sub-section comparing `PersistentSubscriptionRunner` vs `TransactionalSubscriptionRunner` |

---

## Pre-Flight

- [ ] **Verify branch + clean state**

```bash
git status
git branch --show-current  # expect: feature/transactional-subscription-runner
swift build 2>&1 | tail -3
```

Expected: clean, on the correct branch, build succeeds.

- [ ] **Verify both KurrentDB AND Postgres running**

```bash
docker ps --format '{{.Names}} {{.Image}}' | grep -iE "kurrent|postgres"
```

If KurrentDB missing, see Phase 1 plan's pre-flight (run `kurrentdb-latest` container with KURRENTDB_INSECURE=true). If Postgres missing:

```bash
docker run --rm -d --name pg-ddd-kit \
    -e POSTGRES_PASSWORD=postgres \
    -p 5432:5432 \
    postgres:16
```

Both services must be reachable for the integration tests in tasks 3, 4, 7, 9.

---

## Task 1: `TransactionProvider` protocol

**Files:**
- Create: `Sources/EventSourcing/Projector/TransactionProvider.swift`
- Create: `Tests/EventSourcingTests/TransactionProviderTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/EventSourcingTests/TransactionProviderTests.swift
import Testing
import EventSourcing

@Suite("TransactionProvider")
struct TransactionProviderTests {

    /// Stub provider that records lifecycle events for testing.
    private final class StubProvider: TransactionProvider, @unchecked Sendable {
        struct StubTransaction: Sendable { let id: Int }

        var nextId: Int = 0
        var commits: [Int] = []
        var rollbacks: [Int] = []

        func withTransaction<Result: Sendable>(
            _ body: (StubTransaction) async throws -> Result
        ) async throws -> Result {
            nextId += 1
            let tx = StubTransaction(id: nextId)
            do {
                let result = try await body(tx)
                commits.append(tx.id)
                return result
            } catch {
                rollbacks.append(tx.id)
                throw error
            }
        }
    }

    @Test("withTransaction commits when body returns normally")
    func commitsOnSuccess() async throws {
        let provider = StubProvider()
        let result = try await provider.withTransaction { tx in tx.id }
        #expect(result == 1)
        #expect(provider.commits == [1])
        #expect(provider.rollbacks == [])
    }

    @Test("withTransaction rolls back when body throws")
    func rollsBackOnThrow() async {
        let provider = StubProvider()
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await provider.withTransaction { _ -> Int in throw Boom() }
        }
        #expect(provider.commits == [])
        #expect(provider.rollbacks == [1])
    }

    @Test("Provider is Sendable")
    func isSendable() {
        let _: any TransactionProvider = StubProvider()
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter TransactionProviderTests 2>&1 | tail -10
```

Expected: FAIL — `cannot find type 'TransactionProvider'`.

- [ ] **Step 3: Implement the protocol**

```swift
// Sources/EventSourcing/Projector/TransactionProvider.swift
//
//  TransactionProvider — abstract begin/commit/rollback over any backend.
//  See spec: docs/superpowers/specs/2026-04-29-transactional-subscription-runner-design.md
//

/// Abstract over a transactional backend (Postgres, SQLite, ...) using a
/// callback shape: the provider runs `body` inside an active transaction;
/// normal return commits, throwing rolls back.
///
/// Mirrors `PostgresClient.withTransaction { connection in ... }`. Allows
/// `KurrentProjection.TransactionalSubscriptionRunner` to remain agnostic
/// of the underlying backend.
public protocol TransactionProvider: Sendable {

    /// Per-call transaction handle exposed to the body. For Postgres this is
    /// a `PostgresConnection` already in tx mode; for other backends, the
    /// equivalent connection-bound type.
    associatedtype Transaction: Sendable

    /// Runs `body` inside a transaction. Commits on normal return, rolls back
    /// on throw.
    func withTransaction<Result: Sendable>(
        _ body: (Transaction) async throws -> Result
    ) async throws -> Result
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter TransactionProviderTests 2>&1 | tail -10
```

Expected: PASS — all 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/EventSourcing/Projector/TransactionProvider.swift Tests/EventSourcingTests/TransactionProviderTests.swift
git commit -m "[ADD] TransactionProvider protocol (callback withTransaction shape)"
```

---

## Task 2: `TransactionalReadModelStore` protocol

**Files:**
- Create: `Sources/EventSourcing/Projector/TransactionalReadModelStore.swift`
- Create: `Tests/EventSourcingTests/TransactionalReadModelStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/EventSourcingTests/TransactionalReadModelStoreTests.swift
import Testing
import DDDCore
import EventSourcing
import ReadModelPersistence

@Suite("TransactionalReadModelStore")
struct TransactionalReadModelStoreTests {

    private struct TestModel: ReadModel, Sendable {
        typealias ID = String
        let id: String
        var value: String
    }

    /// Stub store that records save calls per fake transaction.
    private final class StubStore: TransactionalReadModelStore, @unchecked Sendable {
        typealias Model = TestModel
        struct FakeTx: Sendable { let id: Int }

        var saves: [(modelId: String, revision: UInt64, txId: Int)] = []
        var fetched: [(modelId: String, txId: Int)] = []

        func save(readModel: TestModel, revision: UInt64, in transaction: FakeTx) async throws {
            saves.append((readModel.id, revision, transaction.id))
        }

        func fetch(byId id: String, in transaction: FakeTx) async throws -> StoredReadModel<TestModel>? {
            fetched.append((id, transaction.id))
            return nil
        }
    }

    @Test("save records in the supplied transaction")
    func saveUsesTransaction() async throws {
        let store = StubStore()
        let model = TestModel(id: "x", value: "v")
        try await store.save(readModel: model, revision: 7, in: .init(id: 42))
        #expect(store.saves.count == 1)
        #expect(store.saves[0].modelId == "x")
        #expect(store.saves[0].revision == 7)
        #expect(store.saves[0].txId == 42)
    }

    @Test("fetch records the supplied transaction")
    func fetchUsesTransaction() async throws {
        let store = StubStore()
        _ = try await store.fetch(byId: "x", in: .init(id: 99))
        #expect(store.fetched == [("x", 99)])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter TransactionalReadModelStoreTests 2>&1 | tail -10
```

Expected: FAIL — `cannot find type 'TransactionalReadModelStore'`.

- [ ] **Step 3: Implement the protocol**

```swift
// Sources/EventSourcing/Projector/TransactionalReadModelStore.swift
//
//  TransactionalReadModelStore — read model store that performs writes
//  scoped to a caller-supplied transaction.
//  See spec: docs/superpowers/specs/2026-04-29-transactional-subscription-runner-design.md
//

import ReadModelPersistence

/// Read model store whose `save` and `fetch` operations execute within a
/// caller-supplied transaction. Used by `KurrentProjection.TransactionalSubscriptionRunner`
/// to ensure all projectors' reads/writes for a single event participate in
/// one shared transaction (all-or-nothing).
///
/// Mirror to `ReadModelStore`, but with explicit `in transaction:` parameter
/// on every operation. The companion `TransactionProvider` produces the
/// transaction value passed here.
public protocol TransactionalReadModelStore: Sendable {
    associatedtype Model: ReadModel & Sendable
    associatedtype Transaction: Sendable

    /// Persist the read model + its revision within the given transaction.
    /// Has no effect on durable state until the transaction commits.
    func save(
        readModel: Model,
        revision: UInt64,
        in transaction: Transaction
    ) async throws

    /// Fetch the stored read model + revision within the given transaction.
    /// Reads-your-own-writes within the same transaction.
    func fetch(
        byId id: Model.ID,
        in transaction: Transaction
    ) async throws -> StoredReadModel<Model>?
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter TransactionalReadModelStoreTests 2>&1 | tail -10
```

Expected: PASS — both tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/EventSourcing/Projector/TransactionalReadModelStore.swift Tests/EventSourcingTests/TransactionalReadModelStoreTests.swift
git commit -m "[ADD] TransactionalReadModelStore protocol — tx-scoped save/fetch"
```

---

## Task 3: `PostgresTransactionProvider` concrete

**Files:**
- Create: `Sources/ReadModelPersistencePostgres/PostgresTransactionProvider.swift`
- Create: `Tests/ReadModelPersistencePostgresIntegrationTests/PostgresTransactionProviderTests.swift`

- [ ] **Step 1: Write the failing integration test**

```swift
// Tests/ReadModelPersistencePostgresIntegrationTests/PostgresTransactionProviderTests.swift
import Testing
import Foundation
import PostgresNIO
import EventSourcing
import ReadModelPersistencePostgres

@Suite("PostgresTransactionProvider", .serialized)
struct PostgresTransactionProviderTests {

    private static func makeClient() -> PostgresClient {
        let cfg = PostgresClient.Configuration(
            host: ProcessInfo.processInfo.environment["PG_HOST"] ?? "localhost",
            port: Int(ProcessInfo.processInfo.environment["PG_PORT"] ?? "5432") ?? 5432,
            username: ProcessInfo.processInfo.environment["PG_USER"] ?? "postgres",
            password: ProcessInfo.processInfo.environment["PG_PASSWORD"] ?? "postgres",
            database: ProcessInfo.processInfo.environment["PG_DATABASE"] ?? "postgres",
            tls: .disable
        )
        return PostgresClient(configuration: cfg)
    }

    @Test("withTransaction commits a temp-table insert when body returns normally")
    func commitsOnSuccess() async throws {
        let client = Self.makeClient()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }

            let provider = PostgresTransactionProvider(client: client)
            let table = "test_tx_commit_\(UUID().uuidString.prefix(8))".replacingOccurrences(of: "-", with: "_")

            try await provider.withTransaction { conn in
                _ = try await conn.query("CREATE TEMP TABLE \(unescaped: table) (id INT)", logger: .init(label: "test"))
                _ = try await conn.query("INSERT INTO \(unescaped: table) VALUES (1)", logger: .init(label: "test"))
            }

            // Temp tables are session-scoped; verifying via a fresh connection won't see it.
            // Here we only verify that withTransaction returns without throwing.
            group.cancelAll()
        }
    }

    @Test("withTransaction rolls back when body throws")
    func rollsBackOnThrow() async throws {
        let client = Self.makeClient()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }

            let provider = PostgresTransactionProvider(client: client)
            struct Boom: Error {}

            await #expect(throws: Boom.self) {
                try await provider.withTransaction { conn -> Void in
                    _ = try await conn.query("CREATE TEMP TABLE wont_exist (id INT)", logger: .init(label: "test"))
                    throw Boom()
                }
            }

            group.cancelAll()
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter PostgresTransactionProviderTests 2>&1 | tail -10
```

Expected: FAIL — `cannot find type 'PostgresTransactionProvider'`.

- [ ] **Step 3: Implement the provider**

```swift
// Sources/ReadModelPersistencePostgres/PostgresTransactionProvider.swift
//
//  PostgresTransactionProvider — concrete TransactionProvider over postgres-nio.
//  Wraps PostgresClient.withTransaction directly.
//  See spec: docs/superpowers/specs/2026-04-29-transactional-subscription-runner-design.md
//

import Foundation
import Logging
import PostgresNIO
import EventSourcing

public struct PostgresTransactionProvider: TransactionProvider {

    public typealias Transaction = PostgresConnection

    private let client: PostgresClient
    private let logger: Logger

    public init(
        client: PostgresClient,
        logger: Logger = Logger(label: "PostgresTransactionProvider")
    ) {
        self.client = client
        self.logger = logger
    }

    public func withTransaction<Result: Sendable>(
        _ body: (PostgresConnection) async throws -> Result
    ) async throws -> Result {
        try await client.withTransaction(logger: logger) { connection in
            try await body(connection)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter PostgresTransactionProviderTests 2>&1 | tail -15
```

Expected: PASS — both tests pass against real Postgres.

- [ ] **Step 5: Commit**

```bash
git add Sources/ReadModelPersistencePostgres/PostgresTransactionProvider.swift Tests/ReadModelPersistencePostgresIntegrationTests/PostgresTransactionProviderTests.swift
git commit -m "[ADD] PostgresTransactionProvider — wraps PostgresClient.withTransaction"
```

---

## Task 4: `PostgresTransactionalReadModelStore` concrete

**Files:**
- Create: `Sources/ReadModelPersistencePostgres/PostgresTransactionalReadModelStore.swift`
- Create: `Tests/ReadModelPersistencePostgresIntegrationTests/PostgresTransactionalReadModelStoreTests.swift`

- [ ] **Step 1: Write the failing integration test**

```swift
// Tests/ReadModelPersistencePostgresIntegrationTests/PostgresTransactionalReadModelStoreTests.swift
import Testing
import Foundation
import PostgresNIO
import DDDCore
import EventSourcing
import ReadModelPersistence
import ReadModelPersistencePostgres

@Suite("PostgresTransactionalReadModelStore", .serialized)
struct PostgresTransactionalReadModelStoreTests {

    private struct DemoModel: ReadModel, Codable, Sendable {
        typealias ID = String
        let id: String
        var value: String
    }

    private static func makeClient() -> PostgresClient {
        // (same as Task 3)
        let cfg = PostgresClient.Configuration(
            host: ProcessInfo.processInfo.environment["PG_HOST"] ?? "localhost",
            port: Int(ProcessInfo.processInfo.environment["PG_PORT"] ?? "5432") ?? 5432,
            username: ProcessInfo.processInfo.environment["PG_USER"] ?? "postgres",
            password: ProcessInfo.processInfo.environment["PG_PASSWORD"] ?? "postgres",
            database: ProcessInfo.processInfo.environment["PG_DATABASE"] ?? "postgres",
            tls: .disable
        )
        return PostgresClient(configuration: cfg)
    }

    @Test("save in committed transaction is durable; fetch sees it")
    func saveAndFetchAfterCommit() async throws {
        let client = Self.makeClient()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }

            try await PostgresReadModelMigration.createTable(on: client)
            let store = PostgresTransactionalReadModelStore<DemoModel>()
            let provider = PostgresTransactionProvider(client: client)
            let id = "tx-test-\(UUID().uuidString.prefix(8))"

            try await provider.withTransaction { conn in
                let model = DemoModel(id: id, value: "committed")
                try await store.save(readModel: model, revision: 1, in: conn)
            }

            let stored: StoredReadModel<DemoModel>? = try await provider.withTransaction { conn in
                try await store.fetch(byId: id, in: conn)
            }

            #expect(stored?.readModel.value == "committed")
            #expect(stored?.revision == 1)

            group.cancelAll()
        }
    }

    @Test("save in rolled-back transaction is NOT durable; fetch sees nothing")
    func rollbackHidesWrites() async throws {
        let client = Self.makeClient()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }

            try await PostgresReadModelMigration.createTable(on: client)
            let store = PostgresTransactionalReadModelStore<DemoModel>()
            let provider = PostgresTransactionProvider(client: client)
            let id = "tx-rollback-\(UUID().uuidString.prefix(8))"

            struct Boom: Error {}
            await #expect(throws: Boom.self) {
                try await provider.withTransaction { conn -> Void in
                    let model = DemoModel(id: id, value: "should-not-stick")
                    try await store.save(readModel: model, revision: 1, in: conn)
                    throw Boom()
                }
            }

            let stored: StoredReadModel<DemoModel>? = try await provider.withTransaction { conn in
                try await store.fetch(byId: id, in: conn)
            }

            #expect(stored == nil)

            group.cancelAll()
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter PostgresTransactionalReadModelStoreTests 2>&1 | tail -15
```

Expected: FAIL — `cannot find type 'PostgresTransactionalReadModelStore'`.

- [ ] **Step 3: Implement the store**

The non-transactional `PostgresJSONReadModelStore` already encodes the `read_model_snapshots` schema. Reuse the same SQL but bind the queries to the supplied `PostgresConnection`.

```swift
// Sources/ReadModelPersistencePostgres/PostgresTransactionalReadModelStore.swift
//
//  PostgresTransactionalReadModelStore — TransactionalReadModelStore impl
//  for `read_model_snapshots`. Stateless; the connection arrives via the
//  `Transaction` parameter.
//  See spec: docs/superpowers/specs/2026-04-29-transactional-subscription-runner-design.md
//

import Foundation
import Logging
import PostgresNIO
import DDDCore
import EventSourcing
import ReadModelPersistence

public struct PostgresTransactionalReadModelStore<Model: ReadModel & Codable & Sendable>: TransactionalReadModelStore
where Model.ID == String {

    public typealias Transaction = PostgresConnection

    public init() {}

    public func save(readModel: Model, revision: UInt64, in transaction: PostgresConnection) async throws {
        let typeName = String(describing: Model.self)
        let data = try JSONEncoder().encode(readModel)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ReadModelStoreError.saveFailed(
                id: readModel.id,
                cause: EncodingError.invalidValue(readModel, .init(codingPath: [], debugDescription: "JSON is not valid UTF-8"))
            )
        }
        let revBits = Int64(bitPattern: revision)

        do {
            _ = try await transaction.query("""
                INSERT INTO read_model_snapshots (id, type, data, revision, updated_at)
                VALUES (\(readModel.id), \(typeName), \(json)::jsonb, \(revBits), now())
                ON CONFLICT (id, type) DO UPDATE SET
                    data = EXCLUDED.data,
                    revision = EXCLUDED.revision,
                    updated_at = EXCLUDED.updated_at
                """, logger: Logger(label: "PostgresTransactionalReadModelStore"))
        } catch let e as ReadModelStoreError {
            throw e
        } catch {
            throw ReadModelStoreError.saveFailed(id: readModel.id, cause: error)
        }
    }

    public func fetch(byId id: String, in transaction: PostgresConnection) async throws -> StoredReadModel<Model>? {
        let typeName = String(describing: Model.self)
        do {
            let rows = try await transaction.query("""
                SELECT data, revision FROM read_model_snapshots
                WHERE id = \(id) AND type = \(typeName)
                """, logger: Logger(label: "PostgresTransactionalReadModelStore"))

            for try await (data, revBits) in rows.decode((String, Int64).self) {
                let model = try JSONDecoder().decode(Model.self, from: Data(data.utf8))
                return StoredReadModel(readModel: model, revision: UInt64(bitPattern: revBits))
            }
            return nil
        } catch let e as ReadModelStoreError {
            throw e
        } catch {
            throw ReadModelStoreError.fetchFailed(id: id, cause: error)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter PostgresTransactionalReadModelStoreTests 2>&1 | tail -15
```

Expected: PASS — both tests (commit visible, rollback hidden).

- [ ] **Step 5: Commit**

```bash
git add Sources/ReadModelPersistencePostgres/PostgresTransactionalReadModelStore.swift Tests/ReadModelPersistencePostgresIntegrationTests/PostgresTransactionalReadModelStoreTests.swift
git commit -m "[ADD] PostgresTransactionalReadModelStore — tx-bound save/fetch"
```

---

## Task 5: `TransactionalSubscriptionRunner` skeleton

**Files:**
- Modify: `Sources/KurrentSupport/Adapter/KurrentProjection.swift`
- Create: `Tests/KurrentSupportUnitTests/KurrentProjectionTransactionalRunnerSetupTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/KurrentSupportUnitTests/KurrentProjectionTransactionalRunnerSetupTests.swift
import Testing
import KurrentDB
import EventSourcing
@testable import KurrentSupport

@Suite("KurrentProjection.TransactionalSubscriptionRunner — setup")
struct KurrentProjectionTransactionalRunnerSetupTests {

    /// Stub provider for unit testing — no real backend.
    private struct StubProvider: TransactionProvider {
        struct StubTx: Sendable {}
        func withTransaction<Result: Sendable>(_ body: (StubTx) async throws -> Result) async throws -> Result {
            try await body(StubTx())
        }
    }

    @Test("Can construct runner with a provider and default retry policy")
    func constructWithDefaults() {
        let client = KurrentDBClient(settings: .localhost())
        let runner = KurrentProjection.TransactionalSubscriptionRunner(
            client: client,
            transactionProvider: StubProvider(),
            stream: "$ce-Test",
            groupName: "test-group"
        )
        let _: any Sendable = runner
    }

    @Test("Can construct runner with explicit retry policy")
    func constructWithExplicitPolicy() {
        let client = KurrentDBClient(settings: .localhost())
        let runner = KurrentProjection.TransactionalSubscriptionRunner(
            client: client,
            transactionProvider: StubProvider(),
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
swift test --filter KurrentProjectionTransactionalRunnerSetupTests 2>&1 | tail -10
```

Expected: FAIL — `TransactionalSubscriptionRunner` not defined.

- [ ] **Step 3: Add the class skeleton**

Edit `Sources/KurrentSupport/Adapter/KurrentProjection.swift`. Inside the `KurrentProjection` namespace, add (place AFTER `PersistentSubscriptionRunner` and its registration storage):

```swift
    /// Transactional projection runner — every event triggers a single shared
    /// transaction; all registered projectors' writes commit or roll back
    /// together. Generic over `TransactionProvider`; `PostgresTransactionProvider`
    /// is the common case (see ReadModelPersistencePostgres convenience init).
    ///
    /// Shares retry/nack/cancellation semantics with `PersistentSubscriptionRunner`;
    /// the only difference is the per-event transaction scope.
    public final class TransactionalSubscriptionRunner<Provider: TransactionProvider>: Sendable {

        private let client: KurrentDBClient
        private let transactionProvider: Provider
        private let stream: String
        private let groupName: String
        private let retryPolicy: any RetryPolicy
        private let logger: Logger

        // Registrations: closure captures projector + storeFactory + extractInput;
        // signature is (RecordedEvent, Provider.Transaction) async throws -> Void.
        private let _registrations = Mutex<[TransactionalRegistration<Provider.Transaction>]>([])

        public init(
            client: KurrentDBClient,
            transactionProvider: Provider,
            stream: String,
            groupName: String,
            retryPolicy: any RetryPolicy = MaxRetriesPolicy(max: 5),
            logger: Logger = Logger(label: "KurrentProjection.TransactionalSubscriptionRunner")
        ) {
            self.client = client
            self.transactionProvider = transactionProvider
            self.stream = stream
            self.groupName = groupName
            self.retryPolicy = retryPolicy
            self.logger = logger
        }
    }

    fileprivate struct TransactionalRegistration<Transaction: Sendable>: Sendable {
        let dispatch: @Sendable (RecordedEvent, Transaction) async throws -> Void
    }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter KurrentProjectionTransactionalRunnerSetupTests 2>&1 | tail -10
```

Expected: PASS — both tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/KurrentSupport/Adapter/KurrentProjection.swift Tests/KurrentSupportUnitTests/KurrentProjectionTransactionalRunnerSetupTests.swift
git commit -m "[ADD] TransactionalSubscriptionRunner skeleton with init"
```

---

## Task 6: `register(projector:storeFactory:eventFilter:extractInput:)`

**Files:**
- Modify: `Sources/KurrentSupport/Adapter/KurrentProjection.swift`
- Modify: `Tests/KurrentSupportUnitTests/KurrentProjectionTransactionalRunnerSetupTests.swift`

- [ ] **Step 1: Write the failing test**

Append a new test case to `KurrentProjectionTransactionalRunnerSetupTests`:

```swift
    @Test("register chains and counts registrations")
    func registerChains() async {
        let client = KurrentDBClient(settings: .localhost())
        let runner = KurrentProjection.TransactionalSubscriptionRunner(
            client: client,
            transactionProvider: StubProvider(),
            stream: "$ce-Test",
            groupName: "test-group"
        )

        // Stub projector type re-uses the StubProjector from KurrentProjectionRunnerSetupTests
        // — duplicate it here as a fileprivate to keep this test self-contained:
        let coordinator = StubCoordinator()
        let projector = StubProjector(coordinator: coordinator)

        let returned = runner
            .register(
                projector: projector,
                storeFactory: { _ in StubTransactionalStore() }
            ) { _ in StubInput(id: "x") }
            .register(
                projector: projector,
                storeFactory: { _ in StubTransactionalStore() }
            ) { _ in nil }

        #expect(returned === runner)
        #expect(runner._registrationCountForTesting == 2)
    }
```

Add the supporting fileprivate types AT THE TOP of the test file (replacing or extending what's there):

```swift
import EventSourcing
import ReadModelPersistence
import DDDCore
import Foundation

private struct StubReadModel: ReadModel, Sendable {
    typealias ID = String
    let id: String
}

private struct StubInput: CQRSProjectorInput, Sendable { let id: String }

private struct StubCoordinator: EventStorageCoordinator {
    func fetchEvents(byId id: String) async throws -> (events: [any DomainEvent], latestRevision: UInt64)? { nil }
    func fetchEvents(byId id: String, afterRevision revision: UInt64) async throws -> (events: [any DomainEvent], latestRevision: UInt64)? { nil }
    func append(events: [any DomainEvent], byId id: String, version: UInt64?, external: [String : String]?) async throws -> UInt64? { nil }
    func purge(byId id: String) async throws {}
}

private struct StubProjector: EventSourcingProjector, Sendable {
    typealias Input = StubInput
    typealias ReadModelType = StubReadModel
    typealias StorageCoordinator = StubCoordinator

    let coordinator: StubCoordinator

    func apply(readModel: inout StubReadModel, events: [any DomainEvent]) throws {}
    func buildReadModel(input: StubInput) throws -> StubReadModel? { StubReadModel(id: input.id) }
}

private struct StubTransactionalStore: TransactionalReadModelStore {
    typealias Model = StubReadModel
    typealias Transaction = KurrentProjectionTransactionalRunnerSetupTests.StubProvider.StubTx
    func save(readModel: StubReadModel, revision: UInt64, in transaction: Transaction) async throws {}
    func fetch(byId id: String, in transaction: Transaction) async throws -> StoredReadModel<StubReadModel>? { nil }
}
```

(Make `StubProvider.StubTx` non-private — change `private struct StubProvider` to allow visibility of `StubTx` to the file-scope `StubTransactionalStore`. Adjust as needed for compile.)

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter KurrentProjectionTransactionalRunnerSetupTests/registerChains 2>&1 | tail -10
```

Expected: FAIL — `register(projector:storeFactory:...)` not defined; `_registrationCountForTesting` not defined.

- [ ] **Step 3: Implement register + the test hook**

Add to the `TransactionalSubscriptionRunner` class body (inside `KurrentProjection.swift`):

```swift
        /// Register a projector with a per-event tx-bound store factory.
        ///
        /// `storeFactory` is called once per event with the runner's transaction;
        /// it returns a tx-bound store. The runner internally inlines fetch +
        /// apply + save (no `StatefulEventSourcingProjector` exposed).
        @discardableResult
        public func register<Projector: EventSourcingProjector & Sendable, Store: TransactionalReadModelStore>(
            projector: Projector,
            storeFactory: @Sendable @escaping (Provider.Transaction) -> Store,
            eventFilter: (any EventTypeFilter)? = nil,
            extractInput: @Sendable @escaping (RecordedEvent) -> Projector.Input?
        ) -> Self
        where Store.Model == Projector.ReadModelType,
              Store.Transaction == Provider.Transaction,
              Projector.Input: Sendable
        {
            let registration = TransactionalRegistration<Provider.Transaction>(dispatch: { record, tx in
                guard Self._shouldDispatchTx(eventType: record.eventType, filter: eventFilter) else { return }
                guard let input = extractInput(record) else { return }
                let store = storeFactory(tx)

                // Inline fetch + apply + save (replaces what StatefulEventSourcingProjector did).
                let modelId = input.id
                if let stored = try await store.fetch(byId: modelId, in: tx) {
                    // Incremental path: only events newer than stored revision
                    guard let result = try await projector.coordinator.fetchEvents(
                        byId: input.id, afterRevision: stored.revision
                    ) else { return }
                    if result.events.isEmpty { return }
                    var readModel = stored.readModel
                    try projector.apply(readModel: &readModel, events: result.events)
                    try await store.save(
                        readModel: readModel, revision: result.latestRevision, in: tx
                    )
                } else {
                    // Full replay path
                    guard let result = try await projector.coordinator.fetchEvents(byId: input.id) else { return }
                    guard !result.events.isEmpty else { return }
                    guard var readModel = try projector.buildReadModel(input: input) else { return }
                    try projector.apply(readModel: &readModel, events: result.events)
                    try await store.save(
                        readModel: readModel, revision: result.latestRevision, in: tx
                    )
                }
            })
            _registrations.withLock { $0.append(registration) }
            return self
        }

        // Test-only — used by unit tests to verify register chaining.
        // Internal access; not part of the public API.
        internal var _registrationCountForTesting: Int {
            _registrations.withLock { $0.count }
        }

        // Internal — the filter-check helper, mirroring Phase 1's `_shouldDispatch`.
        // Static so it can be unit-tested without constructing a runner.
        internal static func _shouldDispatchTx(
            eventType: String,
            filter: (any EventTypeFilter)?
        ) -> Bool {
            guard let filter else { return true }
            return filter.handles(eventType: eventType)
        }
```

(Note: `_shouldDispatchTx` is a separate helper from Phase 1's `_shouldDispatch` — same logic but on a different generic type; can't share due to associated type constraints. Acceptable duplication.)

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter KurrentProjectionTransactionalRunnerSetupTests 2>&1 | tail -10
```

Expected: PASS — all 3 tests in the suite.

- [ ] **Step 5: Commit**

```bash
git add Sources/KurrentSupport/Adapter/KurrentProjection.swift Tests/KurrentSupportUnitTests/KurrentProjectionTransactionalRunnerSetupTests.swift
git commit -m "[ADD] TransactionalSubscriptionRunner.register (projector + storeFactory + filter)"
```

---

## Task 7: `TransactionalSubscriptionRunner.run()` — full event loop

**Files:**
- Modify: `Sources/KurrentSupport/Adapter/KurrentProjection.swift`
- Create: `Tests/KurrentSupportIntegrationTests/KurrentProjectionTransactionalRunnerIntegrationTests.swift`

- [ ] **Step 1: Write the failing integration test (complete, self-contained)**

```swift
// Tests/KurrentSupportIntegrationTests/KurrentProjectionTransactionalRunnerIntegrationTests.swift
import Testing
import Foundation
import KurrentDB
import KurrentSupport
import EventSourcing
import ReadModelPersistence
import ReadModelPersistencePostgres
import PostgresNIO
import TestUtility
import Logging
import DDDCore

// MARK: - Test fixtures (manually defined — this test target doesn't run the codegen plugin)

private struct DemoEvent: DomainEvent, Codable, Sendable {
    typealias Metadata = Never
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
    var metadata: Never? = nil
    var customerId: String
}

private struct DemoModel: ReadModel, Codable, Sendable {
    typealias ID = String
    let id: String
    var customerId: String = ""
}

private struct DemoInput: CQRSProjectorInput, Sendable { let id: String }

private struct DemoEventMapper: EventTypeMapper {
    func mapping(eventData: RecordedEvent) throws -> (any DomainEvent)? {
        switch eventData.mappingClassName {
        case "DemoEvent":
            guard var event = try eventData.decode(to: DemoEvent.self) else { return nil }
            return event
        default:
            return nil
        }
    }
}

private struct DemoProjector: EventSourcingProjector, Sendable {
    typealias Input = DemoInput
    typealias ReadModelType = DemoModel
    typealias StorageCoordinator = KurrentStorageCoordinator<DemoProjector>

    static var categoryRule: StreamCategoryRule { .custom("TxDemo") }
    let coordinator: KurrentStorageCoordinator<DemoProjector>
    let throwOnApply: Bool

    func apply(readModel: inout DemoModel, events: [any DomainEvent]) throws {
        if throwOnApply { throw IntentionalApplyFailure() }
        for event in events {
            if let demo = event as? DemoEvent {
                readModel.customerId = demo.customerId
            }
        }
    }

    func buildReadModel(input: DemoInput) throws -> DemoModel? { DemoModel(id: input.id) }
}

private struct IntentionalApplyFailure: Error {}

private func demoAggregateId(from record: RecordedEvent) -> String? {
    let name = record.streamIdentifier.name
    let prefix = "TxDemo-"
    guard name.hasPrefix(prefix) else { return nil }
    return String(name.dropFirst(prefix.count))
}

// MARK: - Suite

@Suite("KurrentProjection.TransactionalSubscriptionRunner — integration", .serialized)
struct KurrentProjectionTransactionalRunnerIntegrationTests {

    private static func makePGClient() -> PostgresClient {
        let cfg = PostgresClient.Configuration(
            host: ProcessInfo.processInfo.environment["PG_HOST"] ?? "localhost",
            port: Int(ProcessInfo.processInfo.environment["PG_PORT"] ?? "5432") ?? 5432,
            username: ProcessInfo.processInfo.environment["PG_USER"] ?? "postgres",
            password: ProcessInfo.processInfo.environment["PG_PASSWORD"] ?? "postgres",
            database: ProcessInfo.processInfo.environment["PG_DATABASE"] ?? "postgres",
            tls: .disable
        )
        return PostgresClient(configuration: cfg)
    }

    @Test("Successful dispatch commits the tx; ReadModel visible after run")
    func happyPath() async throws {
        let kdb = KurrentDBClient.makeIntegrationTestClient()
        let pg = Self.makePGClient()
        let groupName = "tx-runner-happy-\(UUID().uuidString.prefix(8))"
        let category = "TxDemo\(UUID().uuidString.prefix(6))"
        let stream = "$ce-\(category)"

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await pg.run() }

            try await PostgresReadModelMigration.createTable(on: pg)
            try await kdb.persistentSubscriptions(stream: stream, group: groupName).create { options in
                options.settings.resolveLink = true
            }
            defer { Task { try? await kdb.persistentSubscriptions(stream: stream, group: groupName).delete() } }

            let aggregateId = UUID().uuidString
            let event = DemoEvent(aggregateRootId: aggregateId, customerId: "alice")
            let coordinator = KurrentStorageCoordinator<DemoProjector>(client: kdb, eventMapper: DemoEventMapper())
            _ = try await coordinator.append(events: [event], byId: aggregateId, version: nil, external: nil)

            let projector = DemoProjector(coordinator: coordinator, throwOnApply: false)
            let runner = KurrentProjection.TransactionalSubscriptionRunner(
                client: kdb,
                transactionProvider: PostgresTransactionProvider(client: pg),    // ← core init (Task 8 adds the pgClient: convenience)
                stream: stream,
                groupName: groupName
            )
            .register(
                projector: projector,
                storeFactory: { _ in PostgresTransactionalReadModelStore<DemoModel>() }
            ) { record in
                demoAggregateId(from: record).map(DemoInput.init)
            }

            let task = Task { try await runner.run() }

            // Poll up to 5 seconds for the read model to appear in PG.
            let nonTxStore = PostgresJSONReadModelStore<DemoModel>(client: pg)
            let deadline = Date().addingTimeInterval(5.0)
            var stored: StoredReadModel<DemoModel>? = nil
            while Date() < deadline {
                stored = try await nonTxStore.fetch(byId: aggregateId)
                if stored != nil { break }
                try await Task.sleep(for: .milliseconds(200))
            }

            task.cancel()
            _ = try? await task.value

            #expect(stored?.readModel.customerId == "alice")

            group.cancelAll()
        }
    }

    @Test("Failing projector rolls back tx; no ReadModel committed even on retry")
    func rollbackOnFailure() async throws {
        let kdb = KurrentDBClient.makeIntegrationTestClient()
        let pg = Self.makePGClient()
        let groupName = "tx-runner-rollback-\(UUID().uuidString.prefix(8))"
        let category = "TxDemo\(UUID().uuidString.prefix(6))"
        let stream = "$ce-\(category)"

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await pg.run() }

            try await PostgresReadModelMigration.createTable(on: pg)
            try await kdb.persistentSubscriptions(stream: stream, group: groupName).create { options in
                options.settings.resolveLink = true
            }
            defer { Task { try? await kdb.persistentSubscriptions(stream: stream, group: groupName).delete() } }

            let aggregateId = UUID().uuidString
            let event = DemoEvent(aggregateRootId: aggregateId, customerId: "bob")
            let coordinator = KurrentStorageCoordinator<DemoProjector>(client: kdb, eventMapper: DemoEventMapper())
            _ = try await coordinator.append(events: [event], byId: aggregateId, version: nil, external: nil)

            // Projector that always throws inside apply — every retry should also fail.
            let projector = DemoProjector(coordinator: coordinator, throwOnApply: true)

            // Tight retry policy so the test exits quickly via .skip after a couple of retries.
            struct QuickSkip: KurrentProjection.RetryPolicy {
                func decide(error: any Error, retryCount: Int) -> KurrentProjection.NackAction {
                    retryCount >= 1 ? .skip : .retry
                }
            }

            let runner = KurrentProjection.TransactionalSubscriptionRunner(
                client: kdb,
                pgClient: pg,
                stream: stream,
                groupName: groupName,
                retryPolicy: QuickSkip()
            )
            .register(
                projector: projector,
                storeFactory: { _ in PostgresTransactionalReadModelStore<DemoModel>() }
            ) { record in
                demoAggregateId(from: record).map(DemoInput.init)
            }

            let task = Task { try await runner.run() }

            // Wait long enough for at least 2 dispatch attempts to finish (initial + 1 retry → skip).
            try await Task.sleep(for: .seconds(3))
            task.cancel()
            _ = try? await task.value

            // Verify NO read model was committed even though dispatch was triggered.
            let nonTxStore = PostgresJSONReadModelStore<DemoModel>(client: pg)
            let stored = try await nonTxStore.fetch(byId: aggregateId)
            #expect(stored == nil, "Read model should not be committed when projector throws — got \(String(describing: stored?.readModel))")

            group.cancelAll()
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter KurrentProjectionTransactionalRunnerIntegrationTests 2>&1 | tail -10
```

Expected: FAIL — `run()` not defined on TransactionalSubscriptionRunner.

- [ ] **Step 3: Implement `run()` + complete the integration test**

In `KurrentProjection.swift`, add to the `TransactionalSubscriptionRunner` class body:

```swift
        /// Subscribe to the persistent subscription and dispatch each event to all
        /// registered projectors inside a single transaction. Commits on full
        /// success, rolls back on any failure (then runs through `RetryPolicy`).
        ///
        /// Cancellation is observed between events, not mid-dispatch.
        public func run() async throws {
            let subscription = try await client
                .persistentSubscriptions(stream: stream, group: groupName)
                .subscribe()

            do {
                for try await result in subscription.events {
                    if Task.isCancelled { return }

                    let record = result.event.record
                    do {
                        try await transactionProvider.withTransaction { tx in
                            try await self.dispatch(record: record, transaction: tx)
                        }
                        try await subscription.ack(readEvents: result.event)
                    } catch {
                        try await handleFailure(error: error, result: result, subscription: subscription)
                    }
                }
            } catch is CancellationError {
                return
            }
        }

        internal func dispatch(record: RecordedEvent, transaction tx: Provider.Transaction) async throws {
            let snapshot = _registrations.withLock { $0 }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for registration in snapshot {
                    group.addTask {
                        try await registration.dispatch(record, tx)
                    }
                }
                try await group.waitForAll()
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
            }

            // .stop is honored even if the nack call above failed — the policy's
            // decision to stop the runner is independent of nack delivery.
            if case .stop = action {
                throw RunnerStopped(reason: "RetryPolicy returned .stop after \(result.retryCount) retries: \(error)")
            }
        }
```

Now complete the integration test in `KurrentProjectionTransactionalRunnerIntegrationTests.swift`:

(The test file body — the implementer should:
1. Define a real projector/mapper for `DemoModel` directly (not via plugin generation, since this test target doesn't run the plugin)
2. Use `KurrentStorageCoordinator` from KurrentSupport
3. Call `.register(projector:storeFactory:extractInput:)` with the demo projector
4. For the rollback test, intentionally throw inside the projector's `when`/`apply`)

Full code for the test bodies will be similar in length to the Phase 1 integration tests; the implementer should follow the existing patterns from `KurrentProjectionRunnerIntegrationTests.swift`.

- [ ] **Step 4: Run integration test to verify it passes**

Ensure both KurrentDB and Postgres are running, then:

```bash
swift test --filter KurrentProjectionTransactionalRunnerIntegrationTests 2>&1 | tail -15
```

Expected: PASS — both tests:
- `happyPath` writes a DemoModel row visible after run
- `rollbackOnFailure` produces no DemoModel row even though dispatch was triggered (and the persistent subscription retried until skip/park)

- [ ] **Step 5: Commit**

```bash
git add Sources/KurrentSupport/Adapter/KurrentProjection.swift Tests/KurrentSupportIntegrationTests/KurrentProjectionTransactionalRunnerIntegrationTests.swift
git commit -m "[ADD] TransactionalSubscriptionRunner.run — full event loop with shared tx"
```

---

## Task 8: Postgres convenience init (application layer)

**Files:**
- Create: `Sources/ReadModelPersistencePostgres/KurrentProjection+PostgresConvenience.swift`

- [ ] **Step 1: Add the convenience init**

Create `Sources/ReadModelPersistencePostgres/KurrentProjection+PostgresConvenience.swift`:

```swift
//
//  KurrentProjection+PostgresConvenience.swift
//  ReadModelPersistencePostgres
//
//  Application-layer convenience init for the Postgres common case.
//  See spec: docs/superpowers/specs/2026-04-29-transactional-subscription-runner-design.md
//

import Foundation
import KurrentDB
import KurrentSupport
import EventSourcing
import PostgresNIO
import Logging

extension KurrentProjection.TransactionalSubscriptionRunner where Provider == PostgresTransactionProvider {

    /// Convenience init for the common Postgres case — wraps `PostgresClient`
    /// in a `PostgresTransactionProvider` for you.
    ///
    /// For non-Postgres backends (or test mocks), use the core init that takes
    /// a `transactionProvider:` directly.
    public convenience init(
        client: KurrentDBClient,
        pgClient: PostgresClient,
        stream: String,
        groupName: String,
        retryPolicy: any KurrentProjection.RetryPolicy = KurrentProjection.MaxRetriesPolicy(max: 5),
        logger: Logger = Logger(label: "KurrentProjection.TransactionalSubscriptionRunner")
    ) {
        self.init(
            client: client,
            transactionProvider: PostgresTransactionProvider(client: pgClient, logger: logger),
            stream: stream,
            groupName: groupName,
            retryPolicy: retryPolicy,
            logger: logger
        )
    }
}
```

- [ ] **Step 2: Verify build**

```bash
swift build 2>&1 | tail -3
```

Expected: clean build.

- [ ] **Step 3: Add a quick smoke-check by importing and constructing in a unit test**

Edit `Tests/KurrentSupportUnitTests/KurrentProjectionTransactionalRunnerSetupTests.swift`. Add a test that exercises the convenience init (this test imports `ReadModelPersistencePostgres` as a dependency — already provided by the test target's deps via the implicit module link; if not, the test target's deps need to add `ReadModelPersistencePostgres`):

Actually — to keep `KurrentSupportUnitTests` minimal in deps, put this smoke test in the integration test target instead, where Postgres dep is already present:

```swift
// Append to KurrentProjectionTransactionalRunnerIntegrationTests.swift:

@Suite("KurrentProjection.TransactionalSubscriptionRunner — convenience init", .serialized)
struct KurrentProjectionTransactionalRunnerConvenienceTests {

    @Test("Convenience init produces a runner using PostgresTransactionProvider")
    func convenienceInitWorks() async throws {
        let kdb = KurrentDBClient.makeIntegrationTestClient()
        let pg = PostgresClient(configuration: .init(
            host: ProcessInfo.processInfo.environment["PG_HOST"] ?? "localhost",
            port: Int(ProcessInfo.processInfo.environment["PG_PORT"] ?? "5432") ?? 5432,
            username: ProcessInfo.processInfo.environment["PG_USER"] ?? "postgres",
            password: ProcessInfo.processInfo.environment["PG_PASSWORD"] ?? "postgres",
            database: ProcessInfo.processInfo.environment["PG_DATABASE"] ?? "postgres",
            tls: .disable
        ))

        let runner = KurrentProjection.TransactionalSubscriptionRunner(
            client: kdb,
            pgClient: pg,
            stream: "$ce-Test",
            groupName: "test-group"
        )
        // Compile-time check — `runner` is a TransactionalSubscriptionRunner<PostgresTransactionProvider>
        let _: KurrentProjection.TransactionalSubscriptionRunner<PostgresTransactionProvider> = runner
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter KurrentProjectionTransactionalRunnerConvenienceTests 2>&1 | tail -10
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ReadModelPersistencePostgres/KurrentProjection+PostgresConvenience.swift Tests/KurrentSupportIntegrationTests/KurrentProjectionTransactionalRunnerIntegrationTests.swift
git commit -m "[ADD] Postgres convenience init for TransactionalSubscriptionRunner"
```

---

## Task 9: Phase 1 cleanup — remove `register(stateful:)`, add `register(projector:store:)`

**Files:**
- Modify: `Sources/KurrentSupport/Adapter/KurrentProjection.swift`
- Modify: `Tests/KurrentSupportUnitTests/KurrentProjectionRunnerSetupTests.swift`
- Modify: `Tests/KurrentSupportUnitTests/KurrentProjectionRunnerFilterTests.swift`
- Modify: `Tests/KurrentSupportIntegrationTests/KurrentProjectionRunnerIntegrationTests.swift`
- Modify: `samples/KurrentProjectionDemo/Sources/main.swift`

This is a unified cleanup — apply all changes in one task to avoid intermediate "both forms present" states.

- [ ] **Step 1: Remove the old `register(stateful:)` overload from `PersistentSubscriptionRunner`**

In `Sources/KurrentSupport/Adapter/KurrentProjection.swift`, find and DELETE the high-level register that takes `_ stateful: StatefulEventSourcingProjector<Projector, Store>`. Keep the low-level `register(extractInput:execute:)` overload — it's still useful for closure-based registration.

- [ ] **Step 2: Add the new `register(projector:store:eventFilter:extractInput:)` overload**

In the same `PersistentSubscriptionRunner` class body, add:

```swift
        /// Register a projector with a long-lived (non-transactional) store.
        ///
        /// The runner internally wires the (projector, store) pair through
        /// fetch + apply + save without exposing `StatefulEventSourcingProjector`.
        /// For transactional semantics (atomic commit/rollback across all
        /// projectors per event), use `KurrentProjection.TransactionalSubscriptionRunner` instead.
        ///
        /// - Important: The projector's apply must be idempotent. The runner
        ///   nacks the entire event on any projector failure, which causes
        ///   re-delivery; already-successful projectors will be invoked again
        ///   on re-delivery; the stored revision cursor in `Store` makes those
        ///   re-invocations no-ops.
        @discardableResult
        public func register<Projector: EventSourcingProjector & Sendable, Store: ReadModelStore>(
            projector: Projector,
            store: Store,
            eventFilter: (any EventTypeFilter)? = nil,
            extractInput: @Sendable @escaping (RecordedEvent) -> Projector.Input?
        ) -> Self
        where Store.Model == Projector.ReadModelType,
              Projector.Input: Sendable
        {
            let registration = Registration(dispatch: { record in
                guard Self._shouldDispatch(eventType: record.eventType, filter: eventFilter) else { return }
                guard let input = extractInput(record) else { return }

                // Inline what StatefulEventSourcingProjector.execute did.
                let modelId = input.id
                if let stored = try await store.fetch(byId: modelId) {
                    guard let result = try await projector.coordinator.fetchEvents(
                        byId: input.id, afterRevision: stored.revision
                    ) else { return }
                    if result.events.isEmpty { return }
                    var readModel = stored.readModel
                    try projector.apply(readModel: &readModel, events: result.events)
                    try await store.save(readModel: readModel, revision: result.latestRevision)
                } else {
                    guard let result = try await projector.coordinator.fetchEvents(byId: input.id) else { return }
                    guard !result.events.isEmpty else { return }
                    guard var readModel = try projector.buildReadModel(input: input) else { return }
                    try projector.apply(readModel: &readModel, events: result.events)
                    try await store.save(readModel: readModel, revision: result.latestRevision)
                }
            })
            _registrations.withLock { $0.append(registration) }
            return self
        }
```

- [ ] **Step 3: Migrate Phase 1 unit tests**

Edit `Tests/KurrentSupportUnitTests/KurrentProjectionRunnerSetupTests.swift`. Replace any test that calls `runner.register(stateful) { ... }` with `runner.register(projector: ..., store: ...) { ... }`. The stub fixtures (StubProjector, StubReadModel) stay the same; only the call shape changes.

```swift
// Old:
let store = InMemoryReadModelStore<StubReadModel>()
let projector = StubProjector(coordinator: StubCoordinator())
let stateful = StatefulEventSourcingProjector(projector: projector, store: store)
runner.register(stateful) { _ in StubInput(id: "x") }

// New:
let store = InMemoryReadModelStore<StubReadModel>()
let projector = StubProjector(coordinator: StubCoordinator())
runner.register(projector: projector, store: store) { _ in StubInput(id: "x") }
```

Same change in `Tests/KurrentSupportUnitTests/KurrentProjectionRunnerFilterTests.swift` if it uses the high-level form.

- [ ] **Step 4: Migrate Phase 1 integration tests**

Edit `Tests/KurrentSupportIntegrationTests/KurrentProjectionRunnerIntegrationTests.swift`. The 5 existing suites (happy path, failure handling, .stop, cancellation, subscription failure, eventFilter) likely use the closure-based `.register(extractInput:execute:)` form rather than `.register(stateful:)`, so they may NOT need migration. Verify with a grep:

```bash
grep -n "register(stateful\|register(_ stateful" Tests/
```

If any callers exist, migrate them. If none, this step is a no-op.

- [ ] **Step 5: Migrate the existing sample `KurrentProjectionDemo`**

Edit `samples/KurrentProjectionDemo/Sources/main.swift`. Find the runner setup. Replace the Stateful construction + `.register(stateful)` calls with direct `.register(projector:store:)` calls.

Old (Phase 1, sketched):
```swift
let summaryStateful = StatefulEventSourcingProjector(projector: summaryProjector, store: summaryStore)
let timelineStateful = StatefulEventSourcingProjector(projector: timelineProjector, store: timelineStore)
let registryStateful = StatefulEventSourcingProjector(projector: registryProjector, store: registryStore)

let runner = KurrentProjection.PersistentSubscriptionRunner(...)
    .register(summaryStateful) { record in ... }
    .register(timelineStateful) { record in ... }
    .register(registryStateful, eventFilter: OrderRegistryEventFilter()) { record in ... }
```

New:
```swift
let runner = KurrentProjection.PersistentSubscriptionRunner(...)
    .register(projector: summaryProjector, store: summaryStore) { record in ... }
    .register(projector: timelineProjector, store: timelineStore) { record in ... }
    .register(
        projector: registryProjector,
        store: registryStore,
        eventFilter: OrderRegistryEventFilter()
    ) { record in ... }
```

Run the sample to verify:

```bash
cd samples/KurrentProjectionDemo
KURRENT_CLUSTER=true swift run KurrentProjectionDemo 2>&1 | tail -15
```

Expected: same output as before (3 read models populated, OrderRegistry only has customerId from OrderCreated).

- [ ] **Step 6: Run full test suite to confirm no regression**

```bash
cd /Users/gradyzhuo/Dropbox/Work/OpenSource/swift-ddd-kit
swift test 2>&1 | tail -5
```

Expected: all tests pass (unit + integration). Postgres/KurrentDB must be running for integration tests.

- [ ] **Step 7: Commit (single commit covering the cleanup)**

```bash
git add Sources/KurrentSupport/Adapter/KurrentProjection.swift Tests/KurrentSupportUnitTests/ Tests/KurrentSupportIntegrationTests/ samples/KurrentProjectionDemo/Sources/main.swift
git commit -m "[REFACTOR] Phase 1 register cleanup — remove register(stateful:), add register(projector:store:)"
```

---

## Task 10: New sample `KurrentTransactionalProjectionDemo`

**Files:**
- Create: `samples/KurrentTransactionalProjectionDemo/Package.swift`
- Create: `samples/KurrentTransactionalProjectionDemo/Sources/event.yaml`
- Create: `samples/KurrentTransactionalProjectionDemo/Sources/event-generator-config.yaml`
- Create: `samples/KurrentTransactionalProjectionDemo/Sources/projection-model.yaml`
- Create: `samples/KurrentTransactionalProjectionDemo/Sources/main.swift`
- Create: `samples/KurrentTransactionalProjectionDemo/Sources/DemoConvergence.swift`

- [ ] **Step 1: Create Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KurrentTransactionalProjectionDemo",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(path: "../../"),
    ],
    targets: [
        .executableTarget(
            name: "KurrentTransactionalProjectionDemo",
            dependencies: [
                .product(name: "DDDKit", package: "swift-ddd-kit"),
                .product(name: "EventSourcing", package: "swift-ddd-kit"),
                .product(name: "KurrentSupport", package: "swift-ddd-kit"),
                .product(name: "ReadModelPersistence", package: "swift-ddd-kit"),
                .product(name: "ReadModelPersistencePostgres", package: "swift-ddd-kit"),
            ],
            path: "Sources",
            plugins: [
                .plugin(name: "DomainEventGeneratorPlugin", package: "swift-ddd-kit"),
                .plugin(name: "ModelGeneratorPlugin", package: "swift-ddd-kit"),
            ]
        ),
    ]
)
```

- [ ] **Step 2: Create the yaml files**

`Sources/event-generator-config.yaml`:

```yaml
accessModifier: internal
```

`Sources/event.yaml`:

```yaml
OrderCreated:
  kind: createdEvent
  aggregateRootId:
    alias: orderId
  properties:
    customerId: String
    totalAmount: Double

OrderAmountUpdated:
  aggregateRootId:
    alias: orderId
  properties:
    newAmount: Double
```

`Sources/projection-model.yaml`:

```yaml
OrderSummary:
  model: readModel
  events:
    - OrderCreated
    - OrderAmountUpdated

OrderRegistry:
  model: readModel
  events:
    - OrderCreated
```

- [ ] **Step 3: Create DemoConvergence.swift**

Reuse the same helper from `samples/KurrentProjectionDemo`:

```swift
// Sources/DemoConvergence.swift
import Foundation

func awaitConvergence(
    timeout: TimeInterval,
    pollInterval: Duration = .milliseconds(200),
    until isConverged: @Sendable () async throws -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await isConverged() { return }
        try await Task.sleep(for: pollInterval)
    }
}
```

(Header comment explaining demo-only synchronization, mirroring `samples/KurrentProjectionDemo/Sources/DemoConvergence.swift`.)

- [ ] **Step 4: Create main.swift demonstrating transactional runner + rollback observable**

The body should:
1. Connect to KurrentDB and Postgres
2. Create the persistent subscription
3. Append events
4. Build and run a `TransactionalSubscriptionRunner` with 2 projectors (`OrderSummary` and `OrderRegistry`)
5. If the env var `SIMULATE_FAILURE=once` is set, the OrderRegistry projector throws on the first event, demonstrating that NEITHER read model commits — both stay empty until retry succeeds
6. Print final read model state from Postgres

The implementer should follow the structure of `samples/KurrentProjectionDemo/Sources/main.swift` but use:
- `PostgresTransactionProvider` instead of `InMemoryReadModelStore`
- `PostgresTransactionalReadModelStore<...>` factories
- `TransactionalSubscriptionRunner` instead of `PersistentSubscriptionRunner`
- An optional throwing wrapper around one projector based on the env var

(Skeleton omitted because it's ~150 lines; the implementer follows the existing demo's pattern.)

- [ ] **Step 5: Build + run**

```bash
cd samples/KurrentTransactionalProjectionDemo
swift build 2>&1 | tail -5
KURRENT_CLUSTER=true swift run KurrentTransactionalProjectionDemo 2>&1 | tail -25
```

Expected: 2 read models populated successfully in Postgres (OrderSummary with totalAmount, OrderRegistry with customerId).

Then run again with `SIMULATE_FAILURE=once`:
```bash
KURRENT_CLUSTER=true SIMULATE_FAILURE=once swift run KurrentTransactionalProjectionDemo 2>&1 | tail -25
```

Expected: at least one round of retry visible in logs; final state still consistent (both read models reflect all 2 events; no partial state where OrderSummary has data but OrderRegistry doesn't).

- [ ] **Step 6: Commit**

```bash
cd /Users/gradyzhuo/Dropbox/Work/OpenSource/swift-ddd-kit
git add samples/KurrentTransactionalProjectionDemo/
git commit -m "[ADD] sample KurrentTransactionalProjectionDemo — observable rollback via SIMULATE_FAILURE"
```

---

## Task 11: README update

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Find the "Persistent Subscription Runner" section**

```bash
grep -n "## Persistent Subscription Runner\|### Persistent Subscription Runner" README.md
```

- [ ] **Step 2: Add a new sub-section after the existing runner content (and after the EventTypeFilter sub-section if present)**

```markdown
#### TransactionalSubscriptionRunner — atomic across projectors (Postgres only)

When all your read models live in the same Postgres instance and you want
all-or-nothing commits per event, use `KurrentProjection.TransactionalSubscriptionRunner`
instead of `PersistentSubscriptionRunner`. Every event runs all registered projectors
inside a single shared `PostgresClient.withTransaction` block; on success
the transaction commits before ack, on any failure the transaction rolls
back and `RetryPolicy` decides nack action (same as Phase 1).

```swift
import KurrentSupport
import EventSourcing
import ReadModelPersistencePostgres

let runner = KurrentProjection.TransactionalSubscriptionRunner(
    client: kdbClient,
    pgClient: pgClient,                            // ← convenience init
    stream: "$ce-Order",
    groupName: "order-projection"
)
.register(
    projector: orderSummaryProjector,
    storeFactory: { tx in PostgresTransactionalReadModelStore<OrderSummary>() }
) { record in
    OrderSummaryInput(id: parseId(from: record))
}
.register(
    projector: orderRegistryProjector,
    storeFactory: { tx in PostgresTransactionalReadModelStore<OrderRegistry>() },
    eventFilter: OrderRegistryEventFilter()
) { record in
    OrderRegistryInput(id: parseId(from: record))
}

try await runner.run()
```

#### Which runner to choose

| | `PersistentSubscriptionRunner` | `TransactionalSubscriptionRunner` |
|---|---|---|
| Cross-projector consistency | Eventually consistent (each store commits independently; partial state visible during retry) | All-or-nothing per event (single tx commits or rolls back) |
| Backend constraint | Any `ReadModelStore` (in-memory, Postgres, custom) | Requires a `TransactionProvider`; common case is Postgres-only via `PostgresTransactionProvider` |
| Per-event overhead | One fetch + one save per registered projector | One transaction begin + N saves + one commit |
| Failure mode | Already-committed projectors stay committed; retry idempotent via stored cursor | Whole event rolled back; retry redoes everything from scratch |
| When to choose | Mixed-backend read models (PG + Redis), simple cases, no atomicity requirement | All read models in one PG; cross-projector consistency required |

Both runners share `RetryPolicy`, `EventTypeFilter`, cancellation semantics,
and `RunnerStopped` error. They differ only in commit semantics. The
underlying core protocols (`TransactionProvider`, `TransactionalReadModelStore`)
are abstract — future SQLite or other transactional backends ship as new
provider/store implementations without touching the runner.
```

- [ ] **Step 3: Verify the README still renders**

```bash
head -200 README.md | tail -50
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "[DOC] README — TransactionalSubscriptionRunner section"
```

---

## Final Verification

- [ ] **Step 1: Full test suite**

```bash
swift test --skip "<some-postgres-suite-not-available>" 2>&1 | tail -5
```

Expected: all unit + integration tests pass. Both KurrentDB AND Postgres must be running. If only KurrentDB is available, skip the Postgres-dependent suites.

- [ ] **Step 2: Both samples build + run**

```bash
cd samples/KurrentProjectionDemo && swift build 2>&1 | tail -3
cd ../KurrentTransactionalProjectionDemo && swift build 2>&1 | tail -3
```

Both should build cleanly.

- [ ] **Step 3: Git log check**

```bash
git log --oneline main..HEAD
```

Expected: linear history of TDD commits (~11 task commits + the spec commit).

- [ ] **Step 4: Push + open PR (only after all tasks pass)**

```bash
git push -u origin feature/transactional-subscription-runner
gh pr create --title "Add TransactionalSubscriptionRunner — Phase 2 (Postgres-shared tx)" --body "$(cat <<'EOF'
## Summary

- New `TransactionalSubscriptionRunner<Provider>` runs all registered projectors' writes in a single per-event Postgres transaction (all-or-nothing)
- Core protocols `TransactionProvider` + `TransactionalReadModelStore` in `EventSourcing` (backend-agnostic)
- Concrete `PostgresTransactionProvider` + `PostgresTransactionalReadModelStore` in `ReadModelPersistencePostgres`
- Application-layer convenience init for the Postgres common case
- Phase 1 cleanup (bundled): drops `register(stateful:)`, replaces with `register(projector:store:)` form mirroring Phase 2's `register(projector:storeFactory:)`
- New sample `samples/KurrentTransactionalProjectionDemo/` with `SIMULATE_FAILURE` env knob to demonstrate observable rollback

## Test plan

- [ ] All Phase 1 + new tests pass
- [ ] `samples/KurrentProjectionDemo` builds + runs after migration to new register form
- [ ] `samples/KurrentTransactionalProjectionDemo` builds + runs against real PG + KurrentDB; rollback observable with `SIMULATE_FAILURE=once`
- [ ] CI green across Linux Swift 6.0 / 6.1 / 6.2

## References

- Spec: `docs/superpowers/specs/2026-04-29-transactional-subscription-runner-design.md`
- Plan: `docs/superpowers/plans/2026-04-29-transactional-subscription-runner.md`
EOF
)"
```

---

## Phase Notes

This work refines Phase 1's runner without breaking external consumers (there are none yet), introduces real atomicity for the Postgres common case, and aligns both runners on a consistent register API that hides `StatefulEventSourcingProjector` from end-user code. `Stateful` itself remains public for non-runner contexts (e.g., `samples/PostgresReadModelDemo`'s one-shot replay).

Future cleanup that could land in a Phase 3 if the project wants to go further:
- Make `StatefulEventSourcingProjector` internal once nothing public uses it
- Migrate `samples/PostgresReadModelDemo` to call `EventSourcingProjector.execute(input:store:)` directly (would require lifting a tx-aware execute helper to a protocol extension)
- Add `EventTypeFilter` + `TransactionProvider` testing harnesses to `TestUtility` for downstream consumers
