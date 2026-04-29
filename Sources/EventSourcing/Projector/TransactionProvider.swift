//
//  TransactionProvider.swift
//  EventSourcing
//
//  Abstract begin/commit/rollback over any transactional backend.
//  Uses a `withTransaction { tx in ... }` callback shape — normal return
//  commits, throwing rolls back. Matches postgres-nio's idiom.
//
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
