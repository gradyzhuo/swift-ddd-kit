//
//  PooledKurrentClientFactory.swift
//  TestUtility
//
//  Lets integration tests opt into swift-kurrentdb's KurrentDBPool (CI-only,
//  gated by KURRENTDB_POOL_URLS) without changing behavior for local development.
//

import KurrentDB
import KurrentDBPool

extension KurrentDBClient {
    /// Runs `action` against a client borrowed from `KurrentDBPool` when the pool is
    /// configured (`KURRENTDB_POOL_URLS` set), or against the fixed cluster from
    /// `makeIntegrationTestClient()` otherwise.
    ///
    /// `withBorrowedClient` returns `nil` only when the pool has no members, never as
    /// a result of `action` throwing — so falling back here never masks an error from
    /// a real pooled run.
    public static func withPooledIntegrationTestClient<T: Sendable>(
        _ action: (KurrentDBClient) async throws -> T
    ) async rethrows -> T {
        if let result = try await withBorrowedClient({ borrowed in try await action(borrowed.client) }) {
            return result
        }
        return try await action(.makeIntegrationTestClient())
    }
}
