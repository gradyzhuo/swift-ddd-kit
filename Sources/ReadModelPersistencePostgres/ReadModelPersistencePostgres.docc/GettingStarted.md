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
struct OrderSummaryProjector: OrderSummaryProjectorProtocol, Sendable {
    typealias ReadModelType = OrderSummary
    typealias Input = OrderSummaryInput
    typealias Store = KurrentStorageCoordinator<OrderSummaryProjector, CustomMetadata>
    static var categoryRule: StreamCategoryRule { .custom("Order") }
    let store: Store

    func buildReadModel(input: Input) throws -> OrderSummary? { OrderSummary(id: input.id) }
    func when(readModel: inout OrderSummary, event: OrderCreated) throws {
        readModel.customerId = event.customerId
        readModel.totalAmount = event.totalAmount
    }
    func when(readModel: inout OrderSummary, event: OrderAmountUpdated) throws {
        readModel.totalAmount = event.newAmount
    }
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
restarts it. Nothing restarts it for you: `ServiceGroup` (Swift Service Lifecycle) does not
restart a failed service. Wrap `run()` in a restart loop with backoff (as `ContextForwarder`'s
`ForwarderGroup.runWithRestart` does), or let the process exit and have your process supervisor
restart it.
Pass `subscriptionSetup: .manual` to manage the group yourself.

Automatic recreation assumes the event data survived. If KurrentDB was recreated empty (or the
event history was otherwise reset), the stored snapshot revisions are ahead of the new streams;
run `KurrentProjection.rebuild` instead of relying on auto-recreation.

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
  "Schema evolution and rebuilding" and `KurrentProjection.rebuild(readModels:snapshots:client:stream:group:settings:logger:)`.
