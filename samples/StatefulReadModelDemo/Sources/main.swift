import Foundation
import DDDCore
import EventSourcing
import ReadModelPersistence

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
// It provides:
//   - func when(readModel:event:) requirements for each event type
//   - a default apply(readModel:events:) that dispatches to the above
//
// Conform to OrderSummaryProjectorProtocol — implement one when() per event.

struct OrderProjector: EventSourcingProjector, OrderSummaryProjectorProtocol {
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
//
// StatefulEventSourcingProjector wraps any EventSourcingProjector + ReadModelStore,
// providing incremental (snapshot-based) projection without changing the projector itself.

let coordinator = InMemoryStorageCoordinator()
let store       = InMemoryReadModelStore<OrderSummary>()
let projector   = OrderProjector(coordinator: coordinator)
let stateful    = StatefulEventSourcingProjector(projector: projector, store: store)

let orderId = "order-001"
let input   = OrderProjectorInput(id: orderId)

print("=== Stateful ReadModel Demo ===\n")

// Step 1: Create order → full replay (no snapshot in store)
print("── Step 1: OrderCreated")
_ = try await coordinator.append(
    events: [OrderCreated(orderId: orderId, customerId: "customer-42", totalAmount: 1000)],
    byId: orderId, version: nil, external: nil)
printModel("→ ReadModel (full replay)", try await stateful.execute(input: input))

// Step 2: Update amount → incremental replay
print("── Step 2: OrderAmountUpdated")
_ = try await coordinator.append(
    events: [OrderAmountUpdated(orderId: orderId, newAmount: 1500)],
    byId: orderId, version: nil, external: nil)
printModel("→ ReadModel (incremental)", try await stateful.execute(input: input))

// Step 3: Cancel order → incremental replay
print("── Step 3: OrderCancelled")
_ = try await coordinator.append(
    events: [OrderCancelled(aggregateRootId: orderId)],
    byId: orderId, version: nil, external: nil)
printModel("→ ReadModel (incremental)", try await stateful.execute(input: input))

print("=== Done ===")
