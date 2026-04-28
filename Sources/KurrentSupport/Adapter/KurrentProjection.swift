//
//  KurrentProjection.swift
//  KurrentSupport
//
//  Phase 1 — Persistent Subscription Runner.
//  See spec: docs/superpowers/specs/2026-04-28-kurrent-projection-runner-design.md
//

import KurrentDB
import Logging
import os

public enum KurrentProjection {

    public enum NackAction: Sendable, Equatable {
        case retry
        case skip
        case park
        case stop
    }

    public struct RunnerStopped: Error, Sendable {
        public let reason: String

        public init(reason: String) {
            self.reason = reason
        }
    }

    public protocol RetryPolicy: Sendable {
        func decide(error: any Error, retryCount: Int) -> NackAction
    }

    public struct MaxRetriesPolicy: RetryPolicy {
        public let max: Int

        public init(max: Int = 5) {
            self.max = max
        }

        public func decide(error: any Error, retryCount: Int) -> NackAction {
            retryCount >= max ? .skip : .retry
        }
    }

    public final class PersistentSubscriptionRunner: Sendable {

        private let client: KurrentDBClient
        private let stream: String
        private let groupName: String
        private let retryPolicy: any RetryPolicy
        private let logger: Logging.Logger

        // Registrations are appended via `register` (chainable, sync) and read by `run()`.
        // Convention: register before run. Lock is defensive, not for concurrent register/run.
        private let _registrations = OSAllocatedUnfairLock<[Registration]>(initialState: [])

        public init(
            client: KurrentDBClient,
            stream: String,
            groupName: String,
            retryPolicy: any RetryPolicy = MaxRetriesPolicy(max: 5),
            logger: Logging.Logger = Logging.Logger(label: "KurrentProjection.PersistentSubscriptionRunner")
        ) {
            self.client = client
            self.stream = stream
            self.groupName = groupName
            self.retryPolicy = retryPolicy
            self.logger = logger
        }
    }

    fileprivate struct Registration: Sendable {
        let dispatch: @Sendable (RecordedEvent) async throws -> Void
    }
}
