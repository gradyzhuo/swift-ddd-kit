//
//  PostgresTransactionProvider.swift
//  ReadModelPersistencePostgres
//
//  Concrete TransactionProvider over postgres-nio's PostgresClient.
//  Wraps PostgresClient.withTransaction { conn in ... } directly.
//
//  See spec: docs/superpowers/specs/2026-04-29-transactional-subscription-runner-design.md
//

import Foundation
import Logging
import PostgresNIO
import EventSourcing

/// Concrete `TransactionProvider` for Postgres.
///
/// Delegates to `PostgresClient.withTransaction(...)`: the body receives a
/// `PostgresConnection` already in transaction mode; normal return commits,
/// throwing rolls back.
///
/// postgres-nio wraps any error from the body in `PostgresTransactionError`
/// (capturing begin/closure/rollback/commit errors). To honor the
/// `TransactionProvider` contract — "throwing rolls back", with the body's
/// error visible to the caller — this provider unwraps a clean rollback
/// (`closureError` set, `beginError`/`rollbackError`/`commitError` all nil)
/// and rethrows the original `closureError`. If anything in begin/rollback/
/// commit also failed, the full `PostgresTransactionError` is rethrown so
/// the caller can see the infrastructure failure.
public struct PostgresTransactionProvider: TransactionProvider {

    public typealias Transaction = PostgresConnection

    private let client: PostgresClient
    private let logger: Logger

    public init(
        client: PostgresClient,
        logger: Logger = Logger(label: "PostgresTransactionProvider")
    ) {
        self.client = client
        self.logger = logger
    }

    public func withTransaction<Result: Sendable>(
        _ body: (PostgresConnection) async throws -> Result
    ) async throws -> Result {
        do {
            return try await client.withTransaction(logger: logger) { connection in
                try await body(connection)
            }
        } catch let txError as PostgresTransactionError {
            // Clean rollback: only the body threw, BEGIN/ROLLBACK both succeeded.
            // Surface the original error so callers see their domain error,
            // not a postgres-nio wrapper.
            if let closureError = txError.closureError,
               txError.beginError == nil,
               txError.rollbackError == nil,
               txError.commitError == nil {
                throw closureError
            }
            // Otherwise something went wrong in the transactional plumbing
            // (begin/rollback/commit). Preserve the full diagnostic.
            throw txError
        }
    }
}
