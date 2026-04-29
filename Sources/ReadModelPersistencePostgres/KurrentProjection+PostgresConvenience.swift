//
//  KurrentProjection+PostgresConvenience.swift
//  ReadModelPersistencePostgres
//
//  Application-layer convenience init for the Postgres common case.
//  Hides the `TransactionProvider` ceremony for users who just want PG.
//
//  See spec: docs/superpowers/specs/2026-04-29-transactional-subscription-runner-design.md
//

import Foundation
import KurrentDB
import KurrentSupport
import EventSourcing
import PostgresNIO
import Logging

extension KurrentProjection.TransactionalSubscriptionRunner where Provider == PostgresTransactionProvider {

    /// Convenience init for the Postgres common case — wraps `PostgresClient`
    /// in a `PostgresTransactionProvider` for you.
    ///
    /// For non-Postgres backends (or test mocks), use the core init that takes
    /// a `transactionProvider:` directly.
    public convenience init(
        client: KurrentDBClient,
        pgClient: PostgresClient,
        stream: String,
        groupName: String,
        retryPolicy: any KurrentProjection.RetryPolicy = KurrentProjection.MaxRetriesPolicy(max: 5),
        logger: Logger = Logger(label: "KurrentProjection.TransactionalSubscriptionRunner")
    ) {
        self.init(
            client: client,
            transactionProvider: PostgresTransactionProvider(client: pgClient, logger: logger),
            stream: stream,
            groupName: groupName,
            retryPolicy: retryPolicy,
            logger: logger
        )
    }
}
