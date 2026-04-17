# swift-ddd-kit

**swift-ddd-kit** is a Swift framework that brings Domain-Driven Design, Event Sourcing, and CQRS to Server-Side Swift. While the Swift backend ecosystem has grown significantly, the building blocks for production-grade DDD architecture — aggregate roots, event sourcing repositories, CQRS projectors, and event migration — have remained largely absent. swift-ddd-kit fills that gap.

## Overview

This framework focuses on:

- Modeling business logic using **Aggregate Roots** as consistency boundaries
- Capturing every state change as an immutable **Domain Event**
- Replaying events to reconstruct state (**Event Sourcing**)
- Separating write and read models through **CQRS Projectors**
- Evolving event schemas safely with **Migration utilities**
- Reducing boilerplate via **SPM build-tool plugins** (YAML → Swift code generation)

## Architecture

Write and Read are fully independent — they share no direct coupling. Both reach into KurrentDB separately: the Write side appends domain events; the Read side reads those same events to build query-optimized models.

![Architecture Diagram](assets/architecture.png)

<details>
<summary>ASCII version</summary>

```
 ┌─────────────────────── FRAMEWORKS & DRIVERS ───────────────────────────────┐
 │         KurrentDB                              PostgreSQL / Memory         │
 │        (Event Store)                            (Read Store)               │
 └──────────────┬───────────────────────────────────────────────┬─────────────┘
                │ ↑ appends           reads events ↓ ───────►   │ ↑ persists
 ┌──────────────┴──────────────────────┬────────────────────────┴─────────────┐
 │     WRITE SIDE (Command)            │     READ SIDE (Query)                │
 ├─────────────────────────────────────┼──────────────────────────────────────┤
 │ INTERFACE ADAPTERS                  │ INTERFACE ADAPTERS                   │
 │   Command Handler  (Controller)     │   Query Handler  (Presenter)         │
 │   KurrentStorageCoordinator(Gateway)│   KurrentStorageCoordinator(Gateway) │
 │                                     │   ReadModelStore  (Gateway)          │
 ├─────────────────────────────────────┼──────────────────────────────────────┤
 │ USE CASES                           │ USE CASES                            │
 │   Usecase                           │   EventSourcingProjector             │
 │   EventSourcingRepository           │   ├─ buildReadModel(input:)          │
 │   EventTypeMapper  (Adapter)        │   └─ apply(readModel:events:)        │
 │                                     │   StatefulProjector                  │
 │                                     │   EventTypeMapper  (Adapter)         │
 ├─────────────────────────────────────┼──────────────────────────────────────┤
 │ ENTITIES  (DDDCore)                 │ ENTITIES  (DDDCore)                  │
 │   AggregateRoot                     │   ReadModel                          │
 │   ├─ when(happened:)                │   └─ id (Codable)                    │
 │   ├─ apply(event:)                  │                                      │
 │   └─ ensureInvariant()              │                                      │
 │   DomainEvent                       │                                      │
 └─────────────────────────────────────┴──────────────────────────────────────┘
```

</details>

> Dependency direction follows Clean Architecture: all layers depend inward toward Entities. Interface Adapters (Gateways) implement protocols defined in Use Cases/Entities — never the reverse.

## Flow

### Write Side (Command)

```
Command Handler
  │
  ├─ 1. repository.find(byId:)
  │       └─ fetches event stream from KurrentDB → replays into AggregateRoot
  │
  ├─ 2. aggregate.apply(event:)
  │       ├─ when(happened:)     mutates in-memory state
  │       ├─ ensureInvariant()   validates domain invariants
  │       └─ queues uncommitted events in AggregateRootMetadata
  │
  ├─ 3. repository.save(aggregateRoot:)
  │       └─ appends uncommitted events to KurrentDB (optimistic concurrency)
  │
  └─ 4. eventBus.postAllEvent()
          └─ publishes saved domain events to DomainEventBus subscribers
```

### Read Side (Query)

```
Query Handler
  │
  └─ StatefulEventSourcingProjector.execute(input:)
        │
        ├─ 1. store.fetch(byId:)
        │       └─ loads cached ReadModel snapshot at revision N
        │
        ├─ 2. coordinator.fetchEvents(byId:, afterRevision: N)
        │       └─ retrieves only new events from KurrentDB since last snapshot
        │
        ├─ 3. apply(readModel:events:)
        │       └─ folds new events into the ReadModel
        │
        ├─ 4. store.save(readModel:, revision:)
        │       └─ persists updated snapshot to PostgreSQL or in-memory store
        │
        └─ CQRSProjectorOutput<ReadModel>
```

## Design Principles

**Separation of Concerns** — write model (domain), read model (projection), and infrastructure (event store) are kept distinct and independently replaceable.

**Event-First Thinking** — state is never stored directly; it is always derived by replaying events. Events are the source of truth.

**Explicit Domain Modeling** — business logic lives in aggregate roots. Anemic models with external mutation are avoided by design.

## Why Swift?

- Strong type system catches event schema mismatches at compile time
- Native `async`/`await` concurrency maps cleanly onto event stream consumption
- Swift 6 strict concurrency enables safe multi-actor architectures
- A growing server-side ecosystem (SwiftNIO, Hummingbird, gRPC) makes Swift viable for production backends

## Status

This project is actively evolving. It is intended as:

- A production-capable foundation for Swift backend systems following DDD + Event Sourcing
- A reference implementation for teams exploring these patterns in Swift
- A contribution to the Swift Server ecosystem

Feedback and contributions are welcome. See open [issues](https://github.com/gradyzhuo/swift-ddd-kit/issues) for planned work.

## Requirements

- Swift 6.0+
- macOS 15+ / iOS 16+
- [KurrentDB](https://github.com/gradyzhuo/swift-kurrentdb) (for event persistence)

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/gradyzhuo/swift-ddd-kit.git", from: "0.1.1")
]
```

Then add `DDDKit` and `KurrentSupport` to your target:

```swift
.target(
    name: "MyTarget",
    dependencies: [
        .product(name: "DDDKit", package: "swift-ddd-kit"),
        .product(name: "KurrentSupport", package: "swift-ddd-kit"),
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

swift-ddd-kit includes two SPM build-tool plugins that generate Swift boilerplate at build time.

### DomainEventGeneratorPlugin

Generates typed event structs from `event.yaml`.

```swift
// Package.swift
.target(
    name: "MyTarget",
    plugins: [
        .plugin(name: "DomainEventGeneratorPlugin", package: "swift-ddd-kit")
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
        .plugin(name: "ProjectionModelGeneratorPlugin", package: "swift-ddd-kit")
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

### GenerateKurrentDBProjectionsPlugin

Generates KurrentDB server-side projection `.js` files from `projection-model.yaml`. These projections run inside KurrentDB and route events into per-entity derived streams that Swift projectors read from.

Unlike the build-tool plugins above, this is a **Command Plugin** — you run it on demand:

```bash
swift package --allow-writing-to-package-directory generate-kurrentdb-projections \
  path/to/projection-model.yaml \
  --output projections/
```

Or use the CLI directly:

```bash
swift run generate kurrentdb-projection \
  path/to/projection-model.yaml \
  --output projections/
```

#### YAML schema

Add `category` and `idField` to any `readModel` definition, and the plugin will generate a `.js` file for it. Definitions without `category` are skipped.

| Field | Type | Description |
|-------|------|-------------|
| `category` | String | KurrentDB aggregate category. Generates `fromStreams(["$ce-{category}"])`. Required for JS generation. |
| `idField` | String | Field in `event.body` used to route events to the per-entity stream. Required when any event uses the standard routing (plain string). |

Each item in `events` / `createdEvents` can be:

- **Plain string** — standard routing via `idField`:
  ```yaml
  events:
    - OrderCreated
  ```

- **Mapping with `|` body** — custom JS placed inside the generated `function(state, event)` wrapper:
  ```yaml
  events:
    - OrderReassigned: |
        linkTo("OrderSummary-" + event.body.newOrderId, event);
  ```

Both forms can be mixed in the same list.

#### Example

```yaml
# projection-model.yaml
OrderSummary:
  model: readModel
  category: Order
  idField: orderId
  createdEvents:
    - OrderCreated
  events:
    - OrderUpdated
    - OrderReassigned: |
        linkTo("OrderSummary-" + event.body.newOrderId, event);
```

Generated `projections/OrderSummaryProjection.js`:

```js
fromStreams(["$ce-Order"])
.when({
    $init: function(){ return {} },
    OrderCreated: function(state, event) {
        if (event.isJson) {
            linkTo("OrderSummary-" + event.body["orderId"], event);
        }
    },
    OrderUpdated: function(state, event) {
        if (event.isJson) {
            linkTo("OrderSummary-" + event.body["orderId"], event);
        }
    },
    OrderReassigned: function(state, event) {
        if (event.isJson) {
            linkTo("OrderSummary-" + event.body.newOrderId, event);
        }
    },
});
```

#### Three-tier design

| Tier | YAML | Output |
|------|------|--------|
| Standard routing | `category` + `idField` + plain string events | Fully generated JS |
| Custom handler | Event entry with `\|` body | Boilerplate generated, custom body embedded |
| Full custom | No YAML — hand-written `.js` | Not touched by generator |

Tiers 1 and 2 can be mixed within a single definition. Hand-written `.js` files in `projections/` coexist without conflict.

## Modules

| Module | Purpose |
|--------|---------|
| `DDDKit` | Umbrella import |
| `DDDCore` | Core protocols: `Entity`, `AggregateRoot`, `DomainEvent`, `DomainEventBus` |
| `EventSourcing` | Abstract patterns: `EventStorageCoordinator`, `EventSourcingRepository`, `EventSourcingProjector` |
| `KurrentSupport` | KurrentDB adapter: `KurrentStorageCoordinator`, `EventTypeMapper` |
| `EventBus` | In-memory event bus for local event distribution |
| `MigrationUtility` | Event schema migration framework |
| `ReadModelPersistence` | `ReadModelStore` protocol + in-memory store for read model snapshots |
| `ReadModelPersistencePostgres` | PostgreSQL + JSONB backed `ReadModelStore` (optional dependency) |
| `TestUtility` | Test helpers: `TestBundle`, stream cleanup utilities |

## License

MIT
