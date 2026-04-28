//
//  KurrentProjection.swift
//  KurrentSupport
//
//  Phase 1 — Persistent Subscription Runner.
//  See spec: docs/superpowers/specs/2026-04-28-kurrent-projection-runner-design.md
//

import KurrentDB
import Logging
import os.lock
import EventSourcing
import ReadModelPersistence

public enum KurrentProjection {

    /// Disambiguates `Logger`: importing `os.lock` (for `OSAllocatedUnfairLock`)
    /// transitively exposes `os.Logger`, which collides with `Logging.Logger`.
    /// Nested name lookup inside this enum resolves bare `Logger` to swift-log.
    public typealias Logger = Logging.Logger

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
        private let logger: Logger

        // Registrations are appended via `register` (chainable, sync) and read by `run()`.
        // Convention: register before run. Lock is defensive, not for concurrent register/run.
        private let _registrations = OSAllocatedUnfairLock<[Registration]>(initialState: [])

        public init(
            client: KurrentDBClient,
            stream: String,
            groupName: String,
            retryPolicy: any RetryPolicy = MaxRetriesPolicy(max: 5),
            logger: Logger = Logger(label: "KurrentProjection.PersistentSubscriptionRunner")
        ) {
            self.client = client
            self.stream = stream
            self.groupName = groupName
            self.retryPolicy = retryPolicy
            self.logger = logger
        }

        /// Register a `StatefulEventSourcingProjector`. The `extractInput` closure
        /// is called for each incoming event; return `nil` to skip this projector.
        ///
        /// - Important: The projector's `execute` must be idempotent. The runner
        ///   nacks the entire event on any failure, which causes the event to be
        ///   re-delivered. Already-successful projectors will be invoked again on
        ///   re-delivery; `StatefulEventSourcingProjector` handles this naturally
        ///   via its stored revision cursor (subsequent invocations become no-ops).
        @discardableResult
        public func register<Projector: EventSourcingProjector, Store: ReadModelStore>(
            _ stateful: StatefulEventSourcingProjector<Projector, Store>,
            extractInput: @Sendable @escaping (RecordedEvent) -> Projector.Input?
        ) -> Self
            where Store.Model == Projector.ReadModelType,
                  Projector.Input: Sendable
        {
            return register(extractInput: extractInput) { input in
                _ = try await stateful.execute(input: input)
            }
        }

        @discardableResult
        public func register<Input: Sendable>(
            extractInput: @Sendable @escaping (RecordedEvent) -> Input?,
            execute: @Sendable @escaping (Input) async throws -> Void
        ) -> Self {
            let registration = Registration(dispatch: { record in
                guard let input = extractInput(record) else { return }
                try await execute(input)
            })
            _registrations.withLock { $0.append(registration) }
            return self
        }

        /// Dispatch a single recorded event to all registered projectors in parallel.
        /// Throws if any projector throws (TaskGroup semantics — others are cancelled).
        internal func dispatch(record: RecordedEvent) async throws {
            let snapshot = _registrations.withLock { $0 }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for registration in snapshot {
                    group.addTask {
                        try await registration.dispatch(record)
                    }
                }
                try await group.waitForAll()
            }
        }

        /// Subscribe to the persistent subscription and dispatch each event to all
        /// registered projectors in parallel. Acks on success.
        ///
        /// Returns when the parent `Task` is cancelled. Throws on subscription
        /// connection failure (no auto-reconnect — caller must restart via
        /// ServiceGroup or similar).
        ///
        /// Cancellation is observed between events, not mid-dispatch — once an event
        /// enters `dispatch(record:)` it runs to completion (or until the registered
        /// closures themselves observe `Task.isCancelled`).
        public func run() async throws {
            let subscription = try await client
                .persistentSubscriptions(stream: stream, group: groupName)
                .subscribe()

            for try await result in subscription.events {
                if Task.isCancelled { return }

                let record = result.event.record
                do {
                    try await dispatch(record: record)
                    try await subscription.ack(readEvents: result.event)
                } catch {
                    try await handleFailure(error: error, result: result, subscription: subscription)
                }
            }
        }

        private func handleFailure(
            error: any Error,
            result: PersistentSubscription.EventResult,
            subscription: PersistentSubscriptions<SpecifiedPersistentSubscriptionTarget>.Subscription<PersistentSubscription.EventResult>
        ) async throws {
            let action = retryPolicy.decide(error: error, retryCount: Int(result.retryCount))
            let kurrentAction: PersistentSubscriptions<SpecifiedPersistentSubscriptionTarget>.Nack.Action = switch action {
                case .retry: .retry
                case .skip:  .skip
                case .park:  .park
                case .stop:  .stop
            }
            do {
                try await subscription.nack(
                    readEvents: [result.event],
                    action: kurrentAction,
                    reason: "\(error)"
                )
            } catch let nackError {
                logger.error("nack failed for event \(result.event.record.id): \(nackError)")
                // Continue — nack failure should not crash the run loop.
            }

            if case .stop = action {
                throw RunnerStopped(reason: "RetryPolicy returned .stop after \(result.retryCount) retries: \(error)")
            }
        }

        // Test-only — used by unit tests to verify register chaining.
        // Internal access; not part of the public API.
        internal var registrationCount: Int {
            _registrations.withLock { $0.count }
        }
    }

    fileprivate struct Registration: Sendable {
        let dispatch: @Sendable (RecordedEvent) async throws -> Void
    }
}
