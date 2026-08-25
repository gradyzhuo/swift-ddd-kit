//
//  PooledKurrentClientFactory.swift
//  TestUtility
//
//  Lets integration tests opt into swift-kurrentdb's KurrentDBPool (CI-only,
//  gated by KURRENTDB_POOL_URLS) without changing behavior for local development.
//

import Foundation
import KurrentDB
import KurrentDBPool

/// Thrown when `KURRENTDB_POOL_URLS` is set but `KurrentDBPool.borrow()` could not
/// find a reachable member within its retry budget.
public struct PooledIntegrationTestClientUnavailable: Error, CustomStringConvertible {
    public var description: String {
        "KURRENTDB_POOL_URLS is set, but KurrentDBPool.borrow() exhausted its retry attempts without finding a reachable pool member."
    }
}

extension KurrentDBClient {
    /// Runs `action` against a client borrowed from `KurrentDBPool` when the pool is
    /// configured (`KURRENTDB_POOL_URLS` set), or against the fixed cluster from
    /// `makeIntegrationTestClient()` otherwise.
    ///
    /// The pool-vs-fallback choice is made by checking `KURRENTDB_POOL_URLS` directly,
    /// not by inspecting `withBorrowedClient`'s result: a `nil` from `withBorrowedClient`
    /// means "no reachable member within its retry budget," which happens both when the
    /// pool isn't configured *and* when it is configured but every candidate failed its
    /// liveness check — those two cases must not be treated the same way. When the pool
    /// is configured, a failed borrow throws instead of silently falling back to the
    /// fixed cluster, which would otherwise defeat CI instance isolation and mask the
    /// failure as a false pass against the wrong database.
    public static func withPooledIntegrationTestClient<T: Sendable>(
        _ action: (KurrentDBClient) async throws -> T
    ) async throws -> T {
        guard ProcessInfo.processInfo.environment["KURRENTDB_POOL_URLS"] != nil else {
            return try await action(.makeIntegrationTestClient())
        }
        guard let result = try await withBorrowedClient({ borrowed in try await action(borrowed.client) }) else {
            // `withBorrowedClient` also returns nil when this task was cancelled while
            // waiting for a member or during liveness probing — that's not a dead pool,
            // it's cancellation, and callers need to see it as such.
            try Task.checkCancellation()
            throw PooledIntegrationTestClientUnavailable()
        }
        return result
    }
}
