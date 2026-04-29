//
//  TransactionalReadModelStore.swift
//  ReadModelPersistence
//
//  Read model store that performs writes scoped to a caller-supplied transaction.
//  Mirror of `ReadModelStore` with explicit `in transaction:` parameter.
//  Companion to `EventSourcing.TransactionProvider`.
//
//  Used by `KurrentProjection.TransactionalSubscriptionRunner` to ensure all
//  projectors' reads/writes for a single event participate in one shared
//  transaction (all-or-nothing).
//
//  See spec: docs/superpowers/specs/2026-04-29-transactional-subscription-runner-design.md
//

import EventSourcing

/// Read model store whose `save` and `fetch` operations execute within a
/// caller-supplied transaction. Mirror of `ReadModelStore`.
public protocol TransactionalReadModelStore: Sendable {
    associatedtype Model: ReadModel & Sendable where Model.ID: Sendable
    associatedtype Transaction: Sendable

    // Note: no `delete(byId:in:)` — Phase 2 runner only does fetch + save
    // within a transaction. Add later if needed for compaction or admin flows.

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
