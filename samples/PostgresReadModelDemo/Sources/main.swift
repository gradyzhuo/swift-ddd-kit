import Foundation
import DDDCore
import EventSourcing
import ReadModelPersistence
import ReadModelPersistencePostgres
import PostgresNIO
import NIOPosix

// MARK: - Domain Events

struct OrderCreated: DomainEvent {
    typealias Metadata = Never
    var id: UUID = .init()
    var occurred: Date = .now
    var metadata: Never? = nil
    let aggregateRootId: String
    let customerId: String
    let totalAmount: Double
}

struct OrderAmountUpdated: DomainEvent {
    typealias Metadata = Never
    var id: UUID = .init()
    var occurred: Date = .now
    var metadata: Never? = nil
    let aggregateRootId: String
    let newAmount: Double
}

struct OrderCancelled: DeletedEvent {
    typealias Metadata = Never
    var id: UUID = .init()
    var occurred: Date = .now
    var metadata: Never? = nil
    let aggregateRootId: String

    init(id: UUID, aggregateRootId: String, occurred: Date) {
        self.id = id
        self.aggregateRootId = aggregateRootId
        self.occurred = occurred
    }
}

// MARK: - Read Model

struct OrderSummary: ReadModel, Codable, Sendable {
    let id: String
    var customerId: String
    var totalAmount: Double
    var status: String
}

// MARK: - Projector Input

struct OrderProjectorInput: CQRSProjectorInput {
    let id: String
}

// MARK: - Projector

final class OrderProjector: StatefulEventSourcingProjector {
    typealias ReadModelType = OrderSummary
    typealias Input = OrderProjectorInput
    typealias StorageCoordinator = InMemoryStorageCoordinator

    static var categoryRule: StreamCategoryRule { .custom("Order") }

    let coordinator: InMemoryStorageCoordinator
    let store: PostgresJSONReadModelStore<OrderSummary>

    init(coordinator: InMemoryStorageCoordinator,
         store: PostgresJSONReadModelStore<OrderSummary>) {
        self.coordinator = coordinator
        self.store = store
    }

    func buildReadModel(input: Input) throws -> OrderSummary? {
        OrderSummary(id: input.id, customerId: "", totalAmount: 0, status: "unknown")
    }

    func apply(readModel: inout OrderSummary, events: [any DomainEvent]) throws {
        for event in events {
            switch event {
            case let e as OrderCreated:
                readModel.customerId = e.customerId
                readModel.totalAmount = e.totalAmount
                readModel.status = "active"
            case let e as OrderAmountUpdated:
                readModel.totalAmount = e.newAmount
            case is OrderCancelled:
                readModel.status = "cancelled"
            default:
                break
            }
        }
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

// MARK: - Table Migration

func createTableIfNeeded(client: PostgresClient) async throws {
    try await client.query("""
        CREATE TABLE IF NOT EXISTS read_model_snapshots (
            id         TEXT        NOT NULL,
            type       TEXT        NOT NULL,
            data       JSONB       NOT NULL,
            revision   BIGINT      NOT NULL,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            PRIMARY KEY (id, type)
        )
        """)
}

// MARK: - Entry Point

@main
struct Demo {
    static func main() async throws {
        // ── PostgreSQL 連線設定 ──────────────────────────────────
        // 使用環境變數覆蓋，或直接修改下方的預設值
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

            // ── 建立 table（冪等）────────────────────────────────
            try await createTableIfNeeded(client: pgClient)

            let coordinator = InMemoryStorageCoordinator()
            let store = PostgresJSONReadModelStore<OrderSummary>(client: pgClient)
            let projector = OrderProjector(coordinator: coordinator, store: store)

            let orderId = "order-pg-001"
            let input = OrderProjectorInput(id: orderId)

            // 清除前次執行的快照（方便重複跑）
            try await store.delete(byId: orderId)

            print("=== Postgres ReadModel Demo ===\n")

            // Step 1: 建立訂單 → 全量 replay，快照存入 Postgres
            print("── Step 1: OrderCreated")
            _ = try await coordinator.append(
                events: [OrderCreated(aggregateRootId: orderId,
                                      customerId: "customer-42",
                                      totalAmount: 1000)],
                byId: orderId, version: nil, external: nil)
            printModel("→ ReadModel (full replay → saved to Postgres)",
                       try await projector.execute(input: input))

            // Step 2: 更新金額 → 增量 replay，快照更新
            print("── Step 2: OrderAmountUpdated")
            _ = try await coordinator.append(
                events: [OrderAmountUpdated(aggregateRootId: orderId, newAmount: 1500)],
                byId: orderId, version: nil, external: nil)
            printModel("→ ReadModel (incremental → updated in Postgres)",
                       try await projector.execute(input: input))

            // Step 3: 取消訂單 → 增量 replay
            print("── Step 3: OrderCancelled")
            _ = try await coordinator.append(
                events: [OrderCancelled(aggregateRootId: orderId)],
                byId: orderId, version: nil, external: nil)
            printModel("→ ReadModel (incremental → updated in Postgres)",
                       try await projector.execute(input: input))

            print("=== Done ===")

            group.cancelAll()
        }
    }
}
