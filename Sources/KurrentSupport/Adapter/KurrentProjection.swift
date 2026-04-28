//
//  KurrentProjection.swift
//  KurrentSupport
//
//  Phase 1 — Persistent Subscription Runner.
//  See spec: docs/superpowers/specs/2026-04-28-kurrent-projection-runner-design.md
//

import KurrentDB
import Logging
import Synchronization
import EventSourcing
import ReadModelPersistence

/// Phase 1 of the KurrentDB read-side projection runner.
///
/// `PersistentSubscriptionRunner` subscribes to a KurrentDB persistent subscription
/// and dispatches each incoming event to one or more registered projectors in parallel.
/// Replaces the per-handler `start() { Task { ... } }` boilerplate found in application
/// projection handlers.
///
/// ## Usage
///
/// ```swift
/// let runner = KurrentProjection.PersistentSubscriptionRunner(
///     client: kdbClient,
///     stream: "$ce-Order",
///     groupName: "order-projection"
/// )
/// .register(orderProjector) { record in
///     OrderProjectorInput(orderId: extractId(from: record))
/// }
///
/// try await runner.run()  // Blocks until cancelled or subscription drops.
/// ```
///
/// ## Idempotency contract
///
/// Registered projectors must be idempotent. The runner nacks the entire event on any
/// projector failure, causing KurrentDB to re-deliver the event. Already-successful
/// projectors will be invoked again on re-delivery.
///
/// `StatefulEventSourcingProjector` satisfies this contract automatically via its stored
/// revision cursor (re-invocations become no-ops). Users of the low-level closure overload
/// must ensure their `execute` closure is idempotent.
///
/// ## Lifecycle
///
/// - `run()` blocks until the parent `Task` is cancelled (returns normally) or the
///   subscription connection drops (throws).
/// - The runner does not auto-reconnect — the caller is responsible for re-running it
///   on failure (typically via Swift Service Lifecycle's `ServiceGroup`).
///
/// ## System projection streams
///
/// When subscribing to a system projection stream like `$ce-<Category>` or `$et-<Type>`,
/// you must create the persistent subscription with `resolveLink = true`. Otherwise the
/// `RecordedEvent` delivered to your `extractInput` closure will reference the system
/// stream itself (e.g., `$ce-Order`) rather than the original aggregate stream
/// (e.g., `Order-<id>`). This is a KurrentDB requirement, not enforced by the runner.
///
/// ```swift
/// try await client.persistentSubscriptions(stream: "$ce-Order", group: "...")
///     .create { options in
///         options.settings.resolveLink = true
///     }
/// ```
///
/// ## Phase 2 (deferred)
///
/// Cross-projector transactional rollback (Postgres-shared transaction) is deferred to
/// Phase 2. Phase 1 provides at-least-once delivery + projector-level idempotency only.
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
        private let logger: Logger

        // Registrations are appended via `register` (chainable, sync) and read by `run()`.
        // Convention: register before run. Lock is defensive, not for concurrent register/run.
        private let _registrations = Mutex<[Registration]>([])

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
            eventFilter: (any EventTypeFilter)? = nil,
            extractInput: @Sendable @escaping (RecordedEvent) -> Input?,
            execute: @Sendable @escaping (Input) async throws -> Void
        ) -> Self {
            let registration = Registration(dispatch: { record in
                guard Self._shouldDispatchForTesting(
                    eventType: record.eventType, filter: eventFilter
                ) else { return }
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

            // .stop is honored even if the nack call above failed — the policy's
            // decision to stop the runner is independent of whether the server
            // received the nack message.
            if case .stop = action {
                throw RunnerStopped(reason: "RetryPolicy returned .stop after \(result.retryCount) retries: \(error)")
            }
        }

        // Test-only — used by unit tests to verify register chaining.
        // Internal access; not part of the public API. The leading underscore
        // and `ForTesting` suffix make the testing intent explicit at call sites.
        internal var _registrationCountForTesting: Int {
            _registrations.withLock { $0.count }
        }

        // Test-only — used by unit tests to verify filter integration.
        // Internal access; not part of the public API.
        internal static func _shouldDispatchForTesting(
            eventType: String,
            filter: (any EventTypeFilter)?
        ) -> Bool {
            guard let filter else { return true }
            return filter.handles(eventType: eventType)
        }
    }

    fileprivate struct Registration: Sendable {
        let dispatch: @Sendable (RecordedEvent) async throws -> Void
    }
}
