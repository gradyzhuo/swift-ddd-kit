# Design: TransactionalSubscriptionRunner — Phase 2

**Date:** 2026-04-29
**Status:** Pending review
**Builds on:** Phase 1 (`docs/superpowers/specs/2026-04-28-kurrent-projection-runner-design.md`) and EventTypeFilter (`docs/superpowers/specs/2026-04-28-event-type-filter-design.md`), both merged.

## Context

Phase 1 ships `PersistentSubscriptionRunner` with at-least-once delivery + projector-level idempotency (each `StatefulEventSourcingProjector` has its own revision cursor, retries become no-ops). This is correct but allows partial state: if a single event triggers 9 projectors and one fails, the other 8 have already committed their writes when the runner nacks. Cross-projector consistency exists only in eventually-consistent terms.

Phase 2 closes the partial-failure window for the common case where every projector writes to the same Postgres instance. By running all projectors' writes inside a **single shared Postgres transaction**, "all 9 succeeded" or "all 9 rolled back" becomes a real guarantee — not just an aspiration that depends on idempotent retries.

The same architectural lens used here also applies a second motivation: **API discipline**. Forcing the user to choose between `PersistentSubscriptionRunner` (eventual) and `TransactionalSubscriptionRunner` (atomic) at the type level makes the consistency model an explicit decision instead of an implicit drift.

This spec also corrects a Phase 1 ergonomics issue surfaced during Phase 2 design: forcing end-users to construct `StatefulEventSourcingProjector` adds cognitive load for what is essentially `Projector + Store → execute(input:)` plumbing. Phase 2's register API hides Stateful entirely; Phase 1's `register(_:extractInput:)` form is migrated in the same change.

## Goals

- New `TransactionalSubscriptionRunner<Provider: TransactionProvider>` core type (generic over backend) that runs all registered projectors' writes inside a per-event shared transaction
- New `TransactionProvider` protocol — abstract begin/commit/rollback over any backend
- New `TransactionalReadModelStore` protocol — abstract tx-bound read model writes
- Concrete Postgres impls: `PostgresTransactionProvider`, `PostgresTransactionalReadModelStore`
- Application-layer convenience init that hides `TransactionProvider` for the common Postgres case
- Both runners (Phase 1 + Phase 2) drop `StatefulEventSourcingProjector` from their public register API; new form is `register(projector:store:extractInput:)` (Phase 1) and `register(projector:storeFactory:extractInput:)` (Phase 2)
- `EventTypeFilter` opt-in supported in Phase 2's register (parity with Phase 1)
- All-or-nothing atomicity contract: dispatch → commit → ack; failure at any step rolls back and feeds existing `RetryPolicy` machinery

## Non-Goals

- ❌ Cross-backend distributed transactions (would require 2PC; explicitly rejected)
- ❌ Heterogeneous read model stores within a single transaction (e.g., PG + Redis in one tx — impossible without 2PC)
- ❌ A new retry policy / nack action machinery — Phase 2 reuses Phase 1's exactly
- ❌ Auto-managed PostgresClient lifecycle inside the runner — caller owns the client
- ❌ Hiding the existence of transactions — the API surface is explicit about transactional boundaries

## Architectural Approach

### Core / application layer split

The framework follows a deliberate two-layer design (per project preference):

- **Core layer** — abstract, explicit, generic: `TransactionProvider`, `TransactionalReadModelStore`, `TransactionalSubscriptionRunner<Provider>`. Protocols with associated types. Generic types. No Postgres knowledge in the runner itself.
- **Application layer** — convenience: a `where Provider == PostgresTransactionProvider` extension that lets the common Postgres user skip the protocol ceremony.

End users for Postgres (the 99% case today) interact only with the application layer. Future SQLite or other transactional backends ship as a new `TransactionProvider` + `TransactionalReadModelStore` pair without touching core.

### Sequence per event

```
1. dispatch all projectors      ← writes are pending in shared tx
2. commit tx                    ← writes flushed to Postgres
3. ack subscription             ← KurrentDB knows we're done
```

Failure at step 1 or 2 → rollback (if not yet committed) → existing `RetryPolicy` decides nack action. Failure at step 3 (commit succeeded but ack failed) is recovered by cursor idempotency on next delivery (same as Phase 1).

## Module Placement

Same module as Phase 1 — `Sources/KurrentSupport/Adapter/`. Following the project's "all Kurrent things in KurrentSupport" boundary established in Phase 1.

| File | Status |
|---|---|
| `Sources/EventSourcing/Projector/TransactionalReadModelStore.swift` | NEW — protocol |
| `Sources/EventSourcing/Projector/TransactionProvider.swift` | NEW — protocol |
| `Sources/KurrentSupport/Adapter/KurrentProjection.swift` | MODIFY — adds `TransactionalSubscriptionRunner`; cleans up Phase 1's register API |
| `Sources/ReadModelPersistencePostgres/PostgresTransactionProvider.swift` | NEW — concrete |
| `Sources/ReadModelPersistencePostgres/PostgresTransactionalReadModelStore.swift` | NEW — concrete |
| `Sources/ReadModelPersistencePostgres/KurrentProjection+PostgresConvenience.swift` | NEW — application-layer convenience init |

## Public API

### Core: protocols (in `EventSourcing`)

```swift
public protocol TransactionProvider: Sendable {
    associatedtype Transaction: Sendable
    func begin() async throws -> Transaction
    func commit(_ transaction: Transaction) async throws
    func rollback(_ transaction: Transaction) async throws
}

public protocol TransactionalReadModelStore<Transaction>: Sendable {
    associatedtype Model: ReadModel & Sendable
    associatedtype Transaction: Sendable
    func save(readModel: Model, revision: UInt64, in transaction: Transaction) async throws
    func fetch(byId id: Model.ID, in transaction: Transaction) async throws -> StoredReadModel<Model>?
}
```

(`StoredReadModel<Model>` is the existing record-with-revision wrapper — reused as-is from `ReadModelPersistence`.)

### Core: runner (in `KurrentSupport`)

```swift
extension KurrentProjection {

    public final class TransactionalSubscriptionRunner<Provider: TransactionProvider>: Sendable {

        public init(
            client: KurrentDBClient,
            transactionProvider: Provider,
            stream: String,
            groupName: String,
            retryPolicy: any RetryPolicy = MaxRetriesPolicy(max: 5),
            logger: Logger = Logger(label: "KurrentProjection.TransactionalSubscriptionRunner")
        )

        /// Register a projector with a per-event tx-bound store factory.
        ///
        /// `storeFactory` is called once per event with the runner's transaction.
        /// The returned store must write through that transaction. The runner
        /// internally constructs a `StatefulEventSourcingProjector` from the
        /// `projector + store` pair for this dispatch.
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

        public func run() async throws
    }
}
```

### Application layer: Postgres convenience

```swift
// Sources/ReadModelPersistencePostgres/PostgresTransactionProvider.swift
public struct PostgresTransactionProvider: TransactionProvider {
    public typealias Transaction = PostgresTransaction   // exact name TBD; see Open Items

    public init(client: PostgresClient)
    public func begin() async throws -> PostgresTransaction
    public func commit(_ transaction: PostgresTransaction) async throws
    public func rollback(_ transaction: PostgresTransaction) async throws
}

// Sources/ReadModelPersistencePostgres/PostgresTransactionalReadModelStore.swift
public struct PostgresTransactionalReadModelStore<Model: ReadModel & Sendable>: TransactionalReadModelStore {
    public typealias Transaction = PostgresTransaction
    public init()    // stateless — connection comes from the transaction
    public func save(readModel: Model, revision: UInt64, in transaction: PostgresTransaction) async throws
    public func fetch(byId id: Model.ID, in transaction: PostgresTransaction) async throws -> StoredReadModel<Model>?
}

// Sources/ReadModelPersistencePostgres/KurrentProjection+PostgresConvenience.swift
extension KurrentProjection.TransactionalSubscriptionRunner where Provider == PostgresTransactionProvider {
    public convenience init(
        client: KurrentDBClient,
        pgClient: PostgresClient,
        stream: String,
        groupName: String,
        retryPolicy: any RetryPolicy = MaxRetriesPolicy(max: 5),
        logger: Logger = Logger(label: "KurrentProjection.TransactionalSubscriptionRunner")
    )
}
```

End-user (Postgres common case):

```swift
let runner = KurrentProjection.TransactionalSubscriptionRunner(
    client: kdbClient,
    pgClient: pgClient,
    stream: "$ce-Order",
    groupName: "order-projection"
)
.register(
    projector: orderSummaryProjector,
    storeFactory: { tx in PostgresTransactionalReadModelStore<OrderSummary>() }
) { record in
    orderId(from: record).map(OrderSummaryInput.init)
}
.register(
    projector: orderRegistryProjector,
    storeFactory: { tx in PostgresTransactionalReadModelStore<OrderRegistry>() },
    eventFilter: OrderRegistryEventFilter()
) { record in
    orderId(from: record).map(OrderRegistryInput.init)
}

try await runner.run()
```

(Note: `PostgresTransactionalReadModelStore` is stateless because the connection is carried by the `Transaction` parameter. The factory closure exists to let the runner re-use one store factory per registration regardless of how many events arrive — the factory result is short-lived per event.)

### Phase 1 cleanup (bundled in this PR)

`PersistentSubscriptionRunner.register(stateful:)` is **removed**. New form mirrors Phase 2's structure:

```swift
extension KurrentProjection.PersistentSubscriptionRunner {
    @discardableResult
    public func register<Projector: EventSourcingProjector & Sendable, Store: ReadModelStore>(
        projector: Projector,
        store: Store,
        eventFilter: (any EventTypeFilter)? = nil,
        extractInput: @Sendable @escaping (RecordedEvent) -> Projector.Input?
    ) -> Self
        where Store.Model == Projector.ReadModelType,
              Projector.Input: Sendable
}
```

Difference from Phase 2: `store:` is a single instance (long-lived across events); Phase 2's `storeFactory:` is a closure (per-event tx-bound). Same registration ergonomics otherwise.

`StatefulEventSourcingProjector` remains public (used by `samples/PostgresReadModelDemo` for one-shot replay outside a runner). It's just no longer threaded through the runner's API.

## Failure Handling

Reuses Phase 1's `RetryPolicy` + `NackAction` exactly. Per-event flow:

```
do {
    let tx = try await transactionProvider.begin()
    do {
        try await dispatch(record: record, transaction: tx)
        try await transactionProvider.commit(tx)
        try await subscription.ack(readEvents: result.event)
    } catch {
        // Roll back if commit hadn't fired (best-effort).
        try? await transactionProvider.rollback(tx)
        try await handleFailure(error: error, result: result, subscription: subscription)
    }
} catch {
    // Failure to begin a transaction — also goes through RetryPolicy.
    try await handleFailure(error: error, result: result, subscription: subscription)
}
```

Where `handleFailure` is the Phase 1 method (verbatim — the policy decision and nack mapping logic doesn't care whether the runner is transactional).

| Failure point | Behavior |
|---|---|
| `tx.begin()` throws | Treat as event-level failure → `RetryPolicy` → nack |
| Any projector dispatch throws | Rollback tx → `RetryPolicy` → nack |
| `tx.commit()` throws | Rollback (if possible) → `RetryPolicy` → nack |
| `tx.rollback()` throws | Log; do not crash run loop |
| `subscription.ack()` throws AFTER successful commit | Log; KurrentDB will redeliver; cursor idempotency handles it |
| `RetryPolicy` returns `.stop` | Rollback (if possible) → nack(`.stop`) → throw `RunnerStopped` |

## Idempotency Contract

`TransactionalSubscriptionRunner` provides **all-or-nothing per event**: either every registered projector's read model is updated AND its cursor advances, or none. No partial state.

Retried events (because of nack) re-run the entire flow. Already-committed events that get re-delivered (because of post-commit ack failure) are recognized via stored cursor revision — fetch returns no new events, dispatch becomes a no-op, transaction commits an empty change set.

The user contract:
- The projector's `apply(readModel:events:)` must be deterministic
- The store's `save(...:in:)` must be transactional with respect to the provided `Transaction` (no side-channel writes)

These conditions are documented at the protocol level.

## Sample / README

The existing `samples/KurrentProjectionDemo` migrates to the cleaned-up Phase 1 register API (`register(projector:store:)` form). It does NOT switch to the transactional runner — it stays as the lightweight in-memory demo.

A new `samples/KurrentTransactionalProjectionDemo` will be added, demonstrating the transactional runner against a local Postgres. It uses 2+ projectors so atomicity is observable. To make rollback observable, one projector intermittently throws (driven by an env var or a `--simulate-failure` flag) so the user can run the demo twice and see the read model state stay consistent (no partial writes).

README gains a new sub-section under "Persistent Subscription Runner" explaining when to choose `PersistentSubscriptionRunner` vs `TransactionalSubscriptionRunner` (partial-failure tolerance, Postgres requirement, idempotency story).

## Testing Strategy

| Layer | Test target | Coverage |
|---|---|---|
| `TransactionProvider` protocol | `EventSourcingTests` | Contract via a stub provider; verifies begin/commit/rollback can be implemented |
| `TransactionalReadModelStore` protocol | `EventSourcingTests` | Contract via a stub store |
| `PostgresTransactionProvider` | `ReadModelPersistencePostgresIntegrationTests` | Real Postgres begin/commit/rollback |
| `PostgresTransactionalReadModelStore` | `ReadModelPersistencePostgresIntegrationTests` | Real Postgres save/fetch within a tx |
| `TransactionalSubscriptionRunner` | `KurrentSupportUnitTests` | Test hooks (existing `_shouldDispatch` style) for register/dispatch logic with a stub provider |
| `TransactionalSubscriptionRunner` end-to-end | `KurrentSupportIntegrationTests` | Real KurrentDB + real Postgres: 2 projectors, force one to throw, verify both stores roll back; verify all-success commits both |
| Phase 1 register cleanup | `KurrentSupportUnitTests` (existing) | Update existing tests to new `register(projector:store:)` form |

## Open Items

1. **`PostgresTransaction` exact type** — postgres-nio exposes some "active connection in tx state" via `PostgresClient.withTransaction { conn in ... }`. The exact name and shape of the `Transaction` we expose may need to wrap that callback API into a value-passing form. Resolved during plan writing.
2. **Stub-based unit tests for runner-tx interaction** — figure out the smallest test surface that exercises tx lifecycle without real Postgres. Likely a `TransactionProvider` impl that records calls.
3. **Cursor read in transactions** — the existing `StatefulEventSourcingProjector.execute(input:)` reads the stored revision via `store.fetch(byId:)`. For the tx-bound case, this fetch must also use the tx. Verify the contract on `TransactionalReadModelStore.fetch(byId:in:)` covers this.
4. **Naming bikeshed** — `TransactionalSubscriptionRunner` vs `TransactionalProjectionRunner` vs other. Picked `TransactionalSubscriptionRunner` for parity with Phase 1's `PersistentSubscriptionRunner`. Confirm during spec review.
5. **Integration test Postgres setup** — existing `ReadModelPersistencePostgresIntegrationTests` already uses Postgres. Phase 2 integration tests need both Postgres AND KurrentDB running. Document in pre-flight; CI may need to add a Postgres service.

## Out of Scope (deferred)

- A `RestorableAggregateRoot` revival path or other write-side concerns
- Background compaction / vacuum strategies for read model snapshots
- Multi-tenant transaction isolation knobs
- Custom isolation levels (READ COMMITTED is the default; serializable is opt-in via the user's own `PostgresTransactionProvider` subclass if needed in the future)
