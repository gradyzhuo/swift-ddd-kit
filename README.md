# DDDKit

**DDDKit** is a Swift framework that brings Domain-Driven Design, Event Sourcing, and CQRS to Server-Side Swift. While the Swift backend ecosystem has grown significantly, the building blocks for production-grade DDD architecture — aggregate roots, event sourcing repositories, CQRS projectors, and event migration — have remained largely absent. DDDKit fills that gap.

## Requirements

- Swift 6.0+
- macOS 15+ / iOS 16+
- [KurrentDB](https://github.com/gradyzhuo/swift-kurrentdb) (for event persistence)

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/gradyzhuo/swift-dddkit.git", from: "0.1.1")
]
```

Then add `DDDKit` and `KurrentSupport` to your target:

```swift
.target(
    name: "MyTarget",
    dependencies: [
        .product(name: "DDDKit", package: "swift-dddkit"),
        .product(name: "KurrentSupport", package: "swift-dddkit"),
    ]
)
```

## Core Concepts

### 1. Define Domain Events

Events are the source of truth. Every state change is captured as an immutable event.

```swift
// A creation event
struct OrderCreated: DomainEvent {
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
    let customerId: String
}

// A deletion event
struct OrderCancelled: DeletedEvent {
    var id: UUID = .init()
    var occurred: Date = .now
    let aggregateRootId: String
}
```

### 2. Implement an Aggregate Root

The aggregate root is the consistency boundary. All state mutations go through `apply(event:)`, which calls `when(happened:)` to update in-memory state.

```swift
final class Order: AggregateRoot {
    typealias DeletedEventType = OrderCancelled

    let id: String
    private(set) var customerId: String = ""
    var metadata: AggregateRootMetadata = .init()

    init(id: String, customerId: String) throws {
        self.id = id
        try apply(event: OrderCreated(aggregateRootId: id, customerId: customerId))
    }

    required init?(events: [any DomainEvent]) throws {
        guard let first = events.first as? OrderCreated else { return nil }
        self.id = first.aggregateRootId
        try apply(events: events)
    }

    func when(happened event: some DomainEvent) throws {
        switch event {
        case let e as OrderCreated:
            customerId = e.customerId
        default:
            break
        }
    }
}
```

### 3. Implement an Event Mapper

The mapper deserializes raw KurrentDB records back into typed domain events.

```swift
struct OrderEventMapper: EventTypeMapper {
    func mapping(eventData: RecordedEvent) throws -> (any DomainEvent)? {
        switch eventData.eventType {
        case "OrderCreated":   return try eventData.decode(to: OrderCreated.self)
        case "OrderCancelled": return try eventData.decode(to: OrderCancelled.self)
        default:               return nil
        }
    }
}
```

### 4. Implement a Repository

Repositories handle persistence and retrieval through event replay.

```swift
final class OrderRepository: EventSourcingRepository {
    typealias AggregateRootType = Order
    typealias StorageCoordinator = KurrentStorageCoordinator<Order>

    let coordinator: StorageCoordinator

    init(client: KurrentDBClient) {
        coordinator = .init(client: client, eventMapper: OrderEventMapper())
    }
}
```

### 5. Save and Find

```swift
let client = KurrentDBClient(settings: .localhost())
let repository = OrderRepository(client: client)

// Create and save
let order = try Order(id: "order-001", customerId: "customer-42")
try await repository.save(aggregateRoot: order)

// Replay from event stream
let found = try await repository.find(byId: "order-001")

// Soft delete (marks as deleted, still retrievable with hiddingDeleted: false)
try await repository.delete(byId: "order-001")

// Hard delete (irreversible — removes the stream)
try await repository.purge(byId: "order-001")
```

## CQRS — Projectors and Read Models

For the query side, implement `EventSourcingProjector` to fold events into a read-optimized model.

```swift
struct OrderSummary: ReadModel {
    let id: String
    var customerId: String
    var status: String
}

final class OrderProjector: EventSourcingProjector {
    typealias ReadModelType = OrderSummary
    typealias Input = OrderProjectorInput
    typealias StorageCoordinator = KurrentStorageCoordinator<Order>

    let coordinator: StorageCoordinator

    init(client: KurrentDBClient) {
        coordinator = .init(client: client, eventMapper: OrderEventMapper())
    }

    func buildReadModel(input: Input) throws -> OrderSummary? {
        OrderSummary(id: input.id, customerId: "", status: "unknown")
    }

    func apply(readModel: inout OrderSummary, events: [any DomainEvent]) throws {
        for event in events {
            switch event {
            case let e as OrderCreated:
                readModel.customerId = e.customerId
                readModel.status = "active"
            case is OrderCancelled:
                readModel.status = "cancelled"
            default:
                break
            }
        }
    }
}
```

## Event Migration

When event schemas evolve, `MigrationUtility` handles replaying old events through migration handlers without losing history.

```swift
struct MyMigration: Migration {
    typealias AggregateRootType = Order
    var eventMapper: any EventTypeMapper = LegacyOrderEventMapper()
    var migrationHandlers: [any MigrationHandler] = [
        OrderCreatedV1ToV2Handler()
    ]
}
```

## Code Generation Plugins

DDDKit includes two SPM build-tool plugins that generate Swift boilerplate at build time.

### DomainEventGeneratorPlugin

Generates typed event structs from `event.yaml`.

```swift
// Package.swift
.target(
    name: "MyTarget",
    plugins: [
        .plugin(name: "DomainEventGeneratorPlugin", package: "swift-dddkit")
    ]
)
```

`event.yaml` syntax:

```yaml
OrderCreated:
  kind: createdEvent         # createdEvent | domainEvent | deletedEvent (default: domainEvent)
  aggregateRootId:
    alias: orderId           # optional alias for the aggregateRootId property
  properties:
    - name: customerId
      type: String
    - name: totalAmount
      type: Double

OrderCancelled:
  kind: deletedEvent
  aggregateRootId:
    alias: orderId
```

Also requires `event-generator-config.yaml`:

```yaml
accessModifier: public       # internal | package | public
aggregateRootName: Order     # optional, customizes the generated AggregateRoot protocol name
```

### ProjectionModelGeneratorPlugin

Generates `ReadModel` and `EventTypeMapper` boilerplate from `projection-model.yaml`.

```swift
// Package.swift
.target(
    name: "MyTarget",
    plugins: [
        .plugin(name: "ProjectionModelGeneratorPlugin", package: "swift-dddkit")
    ]
)
```

`projection-model.yaml` syntax:

```yaml
OrderSummary:
  model: readModel
  createdEvent: OrderCreated
  deletedEvent: OrderCancelled
  events:
    - OrderItemAdded
    - OrderShipped
```

## Modules

| Module | Purpose |
|--------|---------|
| `DDDKit` | Umbrella import |
| `DDDCore` | Core protocols: `Entity`, `AggregateRoot`, `DomainEvent`, `DomainEventBus` |
| `EventSourcing` | Abstract patterns: `EventStorageCoordinator`, `EventSourcingRepository`, `EventSourcingProjector` |
| `KurrentSupport` | KurrentDB adapter: `KurrentStorageCoordinator`, `EventTypeMapper` |
| `EventBus` | In-memory event bus for local event distribution |
| `MigrationUtility` | Event schema migration framework |
| `TestUtility` | Test helpers: `TestBundle`, stream cleanup utilities |

## License

MIT
