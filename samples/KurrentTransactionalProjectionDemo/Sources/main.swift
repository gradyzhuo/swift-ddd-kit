import Foundation
import DDDCore
import EventSourcing
import KurrentSupport
import KurrentDB
import ReadModelPersistence
import ReadModelPersistencePostgres
import PostgresSupport
import PostgresNIO
import NIOPosix

// MARK: - Read Models (user-defined)

struct OrderSummary: ReadModel, Codable, Sendable {
    let id: String
    var customerId: String = ""
    var totalAmount: Double = 0
    var status: String = "pending"
}

struct OrderRegistry: ReadModel, Codable, Sendable {
    let id: String
    var customerId: String = ""
}

// MARK: - Projector Inputs

struct OrderSummaryInput: CQRSProjectorInput { let id: String }
struct OrderRegistryInput: CQRSProjectorInput { let id: String }

// MARK: - Failure Injection (DEMO-ONLY)
//
// `FailureGate` is a one-shot trip that lets the demo make rollback
// observable. The first time a projector calls `shouldFail()` it gets `true`
// (and throws), every subsequent call gets `false` (so the retry succeeds).
//
// In production you would never inject failure into a projector — this is a
// learning aid to prove the transactional runner's all-or-nothing guarantee:
// when one projector throws, the shared transaction rolls back and the OTHER
// projector's writes are NEVER visible. After the retry, both commit together.

final class FailureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingFailures: Int

    init(failures: Int) { self.remainingFailures = failures }

    func shouldFail() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if remainingFailures > 0 {
            remainingFailures -= 1
            return true
        }
        return false
    }
}

struct IntentionalFailure: Error, CustomStringConvertible {
    var description: String { "IntentionalFailure (demo-only — rollback expected)" }
}

// MARK: - Projectors
//
// The protocols are generated from projection-model.yaml — one per ReadModel:
//   - OrderSummaryProjectorProtocol
//   - OrderRegistryProjectorProtocol
// Each conforming projector accumulates one read model from the same Order events.
//
// `OrderSummaryProjector` carries an optional `FailureGate` — when present and
// armed, the first apply throws. This makes rollback OBSERVABLE: until the
// retry succeeds, neither read model has the event applied (no partial state).

struct OrderSummaryProjector: OrderSummaryProjectorProtocol, Sendable {
    typealias ReadModelType = OrderSummary
    typealias Input = OrderSummaryInput
    typealias StorageCoordinator = KurrentStorageCoordinator<OrderSummaryProjector>

    static var categoryRule: StreamCategoryRule { .custom("Order") }

    let coordinator: KurrentStorageCoordinator<OrderSummaryProjector>
    let failureGate: FailureGate?

    init(coordinator: KurrentStorageCoordinator<OrderSummaryProjector>, failureGate: FailureGate? = nil) {
        self.coordinator = coordinator
        self.failureGate = failureGate
    }

    func buildReadModel(input: Input) throws -> OrderSummary? {
        OrderSummary(id: input.id)
    }

    func when(readModel: inout OrderSummary, event: OrderCreated) throws {
        if failureGate?.shouldFail() == true {
            throw IntentionalFailure()
        }
        readModel.customerId = event.customerId
        readModel.totalAmount = event.totalAmount
        readModel.status = "active"
    }
    func when(readModel: inout OrderSummary, event: OrderAmountUpdated) throws {
        readModel.totalAmount = event.newAmount
    }
}

/// `OrderRegistry` only listens to `OrderCreated`. We pair its `register(...)`
/// call with the auto-generated `OrderRegistryEventFilter` so the runner skips
/// dispatching `OrderAmountUpdated` events to this projector entirely — no
/// `extractInput`, no fetch, no apply, no cursor advance.
struct OrderRegistryProjector: OrderRegistryProjectorProtocol, Sendable {
    typealias ReadModelType = OrderRegistry
    typealias Input = OrderRegistryInput
    typealias StorageCoordinator = KurrentStorageCoordinator<OrderRegistryProjector>

    static var categoryRule: StreamCategoryRule { .custom("Order") }

    let coordinator: KurrentStorageCoordinator<OrderRegistryProjector>

    func buildReadModel(input: Input) throws -> OrderRegistry? {
        OrderRegistry(id: input.id)
    }

    func when(readModel: inout OrderRegistry, event: OrderCreated) throws {
        readModel.customerId = event.customerId
    }
}

// MARK: - Helper to extract orderId from a RecordedEvent (Order-{id} → {id})

func orderId(from record: RecordedEvent) -> String? {
    let name = record.streamIdentifier.name
    let prefix = "Order-"
    guard name.hasPrefix(prefix) else { return nil }
    return String(name.dropFirst(prefix.count))
}

// MARK: - Entry Point

// ── KurrentDB connection ────────────────────────────────────────────────────
// Defaults to local insecure single-node on :2113.
// For TLS / cluster mode, set KURRENT_CLUSTER=true (3-node cluster on :2111-:2113).
let kdbClient: KurrentDBClient = {
    if ProcessInfo.processInfo.environment["KURRENT_CLUSTER"] == "true" {
        let endpoints: [Endpoint] = [
            .init(host: "localhost", port: 2111),
            .init(host: "localhost", port: 2112),
            .init(host: "localhost", port: 2113),
        ]
        let settings = ClientSettings(
            clusterMode: .seeds(endpoints),
            secure: true,
            tlsVerifyCert: false
        )
        .authenticated(.credentials(username: "admin", password: "changeit"))
        return KurrentDBClient(settings: settings)
    } else {
        return KurrentDBClient(settings: .localhost())
    }
}()

// ── PostgreSQL connection ───────────────────────────────────────────────────
let pgHost     = ProcessInfo.processInfo.environment["PG_HOST"]     ?? "localhost"
let pgPort     = Int(ProcessInfo.processInfo.environment["PG_PORT"] ?? "5432") ?? 5432
let pgDatabase = ProcessInfo.processInfo.environment["PG_DATABASE"] ?? "postgres"
let pgUsername = ProcessInfo.processInfo.environment["PG_USER"]     ?? "postgres"
let pgPassword = ProcessInfo.processInfo.environment["PG_PASSWORD"] ?? "postgres"

let pgConfig = PostgresClient.Configuration(
    host: pgHost,
    port: pgPort,
    username: pgUsername,
    password: pgPassword.isEmpty ? nil : pgPassword,
    database: pgDatabase,
    tls: .disable
)

let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let pgClient = PostgresClient(configuration: pgConfig, eventLoopGroup: eventLoopGroup)

// ── Failure-injection knob (DEMO-ONLY) ──────────────────────────────────────
// `SIMULATE_FAILURE=once` arms the gate so OrderSummaryProjector throws on
// the first apply. The transactional runner rolls back the shared tx, retries
// (per RetryPolicy), and the second attempt succeeds — both read models end
// up consistent. Without this env var, the demo runs straight through.
let simulateFailure = ProcessInfo.processInfo.environment["SIMULATE_FAILURE"] == "once"
let failureGate: FailureGate? = simulateFailure ? FailureGate(failures: 1) : nil

let groupName = "kurrent-transactional-projection-demo"
let stream = "$ce-Order"

print("=== KurrentTransactionalProjection Demo ===\n")
print("simulateFailure: \(simulateFailure)\n")

try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { await pgClient.run() }

    // 1. Ensure the read_model_snapshots table exists (idempotent).
    try await PostgresReadModelMigration.createTable(on: pgClient)
    print("✓ Postgres table ready (read_model_snapshots)")

    // Clean any leftover snapshots from previous runs so the demo is repeatable.
    let cleanupStoreSummary = PostgresJSONReadModelStore<OrderSummary>(client: pgClient)
    let cleanupStoreRegistry = PostgresJSONReadModelStore<OrderRegistry>(client: pgClient)

    // 2. Create persistent subscription with resolveLink (idempotent).
    do {
        try await kdbClient.persistentSubscriptions(stream: stream, group: groupName).create { options in
            options.settings.resolveLink = true
        }
        print("✓ Persistent subscription created: \(stream) / \(groupName)")
    } catch {
        // Subscription likely already exists from a previous run — fine for a demo.
        print("ℹ Subscription create skipped (probably already exists)")
    }

    // 3. Build projectors. The shared `mapper` covers both projectors' events.
    let mapper = OrderSummaryEventMapper()

    let orderSummaryProjector = OrderSummaryProjector(
        coordinator: KurrentStorageCoordinator<OrderSummaryProjector>(client: kdbClient, eventMapper: mapper),
        failureGate: failureGate
    )
    let orderRegistryProjector = OrderRegistryProjector(
        coordinator: KurrentStorageCoordinator<OrderRegistryProjector>(client: kdbClient, eventMapper: mapper)
    )

    // 4. Construct the Phase 2 transactional runner via the Postgres
    //    convenience init (hides the `TransactionProvider` ceremony).
    //    Both `.register(...)` calls share the same per-event transaction —
    //    if either throws, BOTH rollback. No partial state.
    let runner = KurrentProjection.TransactionalSubscriptionRunner(
        client: kdbClient,
        pgClient: pgClient,
        stream: stream,
        groupName: groupName
    )
    .register(
        projector: orderSummaryProjector,
        storeFactory: { _ in PostgresTransactionalReadModelStore<OrderSummary>() }
    ) { record in
        orderId(from: record).map { OrderSummaryInput(id: $0) }
    }
    .register(
        projector: orderRegistryProjector,
        storeFactory: { _ in PostgresTransactionalReadModelStore<OrderRegistry>() },
        eventFilter: OrderRegistryEventFilter()  // generated, only OrderCreated
    ) { record in
        orderId(from: record).map { OrderRegistryInput(id: $0) }
    }

    print("✓ Runner configured with 2 projectors (OrderSummary + OrderRegistry — last filtered to OrderCreated only)\n")

    // 5. Launch the runner in the background.
    group.addTask {
        do {
            try await runner.run()
        } catch is CancellationError {
            // Expected on graceful shutdown.
        } catch {
            print("Runner exited with error: \(error)")
        }
    }

    // Give the subscription a moment to connect before publishing.
    try await Task.sleep(for: .milliseconds(500))

    // 6. Publish 3 events for one order on the aggregate stream "Order-{id}".
    let id = "order-tx-demo-\(UUID().uuidString.prefix(6))"
    print("── Publishing events for \(id) ──")

    // Pre-clean any prior snapshots for this id (defensive — id has UUID suffix).
    try? await cleanupStoreSummary.delete(byId: id)
    try? await cleanupStoreRegistry.delete(byId: id)

    let events: [any DomainEvent] = [
        OrderCreated(orderId: id, customerId: "alice", totalAmount: 100),
        OrderAmountUpdated(orderId: id, newAmount: 150),
        OrderAmountUpdated(orderId: id, newAmount: 175),
    ]

    let appendCoordinator = KurrentStorageCoordinator<OrderSummaryProjector>(
        client: kdbClient, eventMapper: mapper
    )
    _ = try await appendCoordinator.append(
        events: events, byId: id, version: nil, external: nil
    )
    print("✓ Appended \(events.count) events\n")

    // 7. DEMO-ONLY synchronization: production code never waits like this.
    //    See `DemoConvergence.swift` for why this exists.
    print("── Waiting for projectors to catch up (demo-only) ──")
    let nonTxSummary = PostgresJSONReadModelStore<OrderSummary>(client: pgClient)
    let nonTxRegistry = PostgresJSONReadModelStore<OrderRegistry>(client: pgClient)

    try await awaitConvergence(timeout: 15.0) {
        let s = try await nonTxSummary.fetch(byId: id)
        let r = try await nonTxRegistry.fetch(byId: id)
        return s?.readModel.totalAmount == 175
            && !(r?.readModel.customerId.isEmpty ?? true)
    }

    // 8. Read final state from Postgres (non-tx fetch).
    let summary = try await nonTxSummary.fetch(byId: id)
    let registry = try await nonTxRegistry.fetch(byId: id)

    print("\n── Final read models (from Postgres) ──")
    if let s = summary?.readModel {
        print("OrderSummary[\(s.id)]:")
        print("  customer:    \(s.customerId)")
        print("  totalAmount: \(s.totalAmount)")
        print("  status:      \(s.status)")
    } else {
        print("OrderSummary: not found (projector did not converge)")
    }
    if let r = registry?.readModel {
        print("\nOrderRegistry[\(r.id)] (filter: only OrderCreated):")
        print("  customer: \(r.customerId)")
    } else {
        print("OrderRegistry: not found (projector did not converge)")
    }

    if simulateFailure {
        print("""

        ── SIMULATE_FAILURE=once ──
        First dispatch threw IntentionalFailure inside the shared transaction.
        The transactional runner rolled back BOTH projectors' writes (no partial
        state was ever visible) and KurrentDB redelivered the event. The retry
        succeeded — both read models above are populated together, atomically.
        """)
    } else {
        print("""

        ── No failure injected ──
        Both projectors committed inside the same transaction on first dispatch.
        Re-run with SIMULATE_FAILURE=once to see rollback + retry in action.
        """)
    }

    print("\n=== Done ===")

    // Graceful shutdown — cancels both runner.run() and pgClient.run().
    group.cancelAll()
}
