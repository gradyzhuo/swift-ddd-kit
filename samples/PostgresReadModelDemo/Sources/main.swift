import Foundation
import DDDCore
import EventSourcing
import ReadModelPersistence
import ReadModelPersistencePostgres
import PostgresNIO
import NIOPosix

// MARK: - Read Model (user-defined)

struct OrderSummary: ReadModel, Codable, Sendable {
    let id: String
    var customerId: String
    var totalAmount: Double
    var status: String
}

// MARK: - Projector Input (user-defined)

struct OrderProjectorInput: CQRSProjectorInput {
    let id: String
}

// MARK: - Projector
//
// OrderSummaryProjectorProtocol is generated from projection-model.yaml.
// Conform to it — implement one when() per event.
// StatefulEventSourcingProjector wraps this projector + the Postgres store.

struct OrderProjector: OrderSummaryProjectorProtocol {
    typealias ReadModelType = OrderSummary
    typealias Input = OrderProjectorInput
    typealias StorageCoordinator = InMemoryStorageCoordinator

    static var categoryRule: StreamCategoryRule { .custom("Order") }

    let coordinator: InMemoryStorageCoordinator

    func buildReadModel(input: Input) throws -> OrderSummary? {
        OrderSummary(id: input.id, customerId: "", totalAmount: 0, status: "unknown")
    }

    func when(readModel: inout OrderSummary, event: OrderCreated) throws {
        readModel.customerId = event.customerId
        readModel.totalAmount = event.totalAmount
        readModel.status = "active"
    }

    func when(readModel: inout OrderSummary, event: OrderAmountUpdated) throws {
        readModel.totalAmount = event.newAmount
    }

    func when(readModel: inout OrderSummary, event: OrderCancelled) throws {
        readModel.status = "cancelled"
    }
}

// MARK: - Helper

func printModel(_ label: String, _ result: CQRSProjectorOutput<OrderSummary>?) {
    guard let m = result?.readModel else { print("\(label): nil\n"); return }
    print("""
    \(label):
      customerId:  \(m.customerId)
      totalAmount: \(m.totalAmount)
      status:      \(m.status)
    """)
}

// MARK: - Entry Point

// ── PostgreSQL connection settings ──────────────────────────────────────────
// Override via environment variables or edit the defaults below
let host     = ProcessInfo.processInfo.environment["PG_HOST"]     ?? "localhost"
let port     = Int(ProcessInfo.processInfo.environment["PG_PORT"] ?? "5432") ?? 5432
let database = ProcessInfo.processInfo.environment["PG_DATABASE"] ?? "postgres"
let username = ProcessInfo.processInfo.environment["PG_USER"]     ?? "postgres"
let password = ProcessInfo.processInfo.environment["PG_PASSWORD"] ?? ""

let config = PostgresClient.Configuration(
    host: host,
    port: port,
    username: username,
    password: password.isEmpty ? nil : password,
    database: database,
    tls: .disable
)

let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let pgClient = PostgresClient(configuration: config, eventLoopGroup: eventLoopGroup)

try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { await pgClient.run() }

    // ── Ensure table exists (idempotent) ────────────────────────────────────
    try await PostgresReadModelMigration.createTable(on: pgClient)

    let coordinator = InMemoryStorageCoordinator()
    let pgStore     = PostgresJSONReadModelStore<OrderSummary>(client: pgClient)
    let projector   = OrderProjector(coordinator: coordinator)
    let stateful    = StatefulEventSourcingProjector(projector: projector, store: pgStore)

    let orderId = "order-pg-001"
    let input   = OrderProjectorInput(id: orderId)

    // Clear any previous snapshot (so demo is repeatable)
    try await pgStore.delete(byId: orderId)

    print("=== Postgres ReadModel Demo ===\n")

    // Step 1: Create order → full replay, snapshot saved to Postgres
    print("── Step 1: OrderCreated")
    _ = try await coordinator.append(
        events: [OrderCreated(orderId: orderId, customerId: "customer-42", totalAmount: 1000)],
        byId: orderId, version: nil, external: nil)
    printModel("→ ReadModel (full replay → saved to Postgres)",
               try await stateful.execute(input: input))

    // Step 2: Update amount → incremental replay, snapshot updated
    print("── Step 2: OrderAmountUpdated")
    _ = try await coordinator.append(
        events: [OrderAmountUpdated(orderId: orderId, newAmount: 1500)],
        byId: orderId, version: nil, external: nil)
    printModel("→ ReadModel (incremental → updated in Postgres)",
               try await stateful.execute(input: input))

    // Step 3: Cancel order → incremental replay
    print("── Step 3: OrderCancelled")
    _ = try await coordinator.append(
        events: [OrderCancelled(aggregateRootId: orderId)],
        byId: orderId, version: nil, external: nil)
    printModel("→ ReadModel (incremental → updated in Postgres)",
               try await stateful.execute(input: input))

    print("=== Done ===")

    group.cancelAll()
}
