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
/// The high-level `register(projector:store:)` overload satisfies this contract
/// automatically via the store's revision cursor (re-invocations become no-ops).
/// Users of the low-level closure overload must ensure their `execute` closure is
/// idempotent.
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

        /// Register a projector with a long-lived (non-transactional) store.
        ///
        /// The runner internally wires the (projector, store) pair through
        /// fetch + apply + save without exposing `StatefulEventSourcingProjector`.
        /// For transactional semantics (atomic commit/rollback across all
        /// projectors per event), use `KurrentProjection.TransactionalSubscriptionRunner` instead.
        ///
        /// - Important: The projector's apply must be idempotent. The runner
        ///   nacks the entire event on any projector failure, which causes
        ///   re-delivery; already-successful projectors will be invoked again
        ///   on re-delivery; the stored revision cursor in `Store` makes those
        ///   re-invocations no-ops.
        @discardableResult
        public func register<Projector: EventSourcingProjector & Sendable, Store: ReadModelStore>(
            projector: Projector,
            store: Store,
            eventFilter: (any EventTypeFilter)? = nil,
            extractInput: @Sendable @escaping (RecordedEvent) -> Projector.Input?
        ) -> Self
        where Store.Model == Projector.ReadModelType,
              Store.Model.ID == String,
              Projector.Input: Sendable
        {
            let registration = Registration(dispatch: { record in
                guard Self._shouldDispatch(eventType: record.eventType, filter: eventFilter) else { return }
                guard let input = extractInput(record) else { return }

                // Incremental fold: fetch from stored revision, apply, save.
                if let stored = try await store.fetch(byId: input.id) {
                    guard let result = try await projector.coordinator.fetchEvents(
                        byId: input.id, afterRevision: stored.revision
                    ) else { return }
                    if result.events.isEmpty { return }
                    var readModel = stored.readModel
                    try projector.apply(readModel: &readModel, events: result.events)
                    try await store.save(readModel: readModel, revision: result.latestRevision)
                } else {
                    guard let result = try await projector.coordinator.fetchEvents(byId: input.id) else { return }
                    guard !result.events.isEmpty else { return }
                    guard var readModel = try projector.buildReadModel(input: input) else { return }
                    try projector.apply(readModel: &readModel, events: result.events)
                    try await store.save(readModel: readModel, revision: result.latestRevision)
                }
            })
            _registrations.withLock { $0.append(registration) }
            return self
        }

        @discardableResult
        public func register<Input: Sendable>(
            eventFilter: (any EventTypeFilter)? = nil,
            extractInput: @Sendable @escaping (RecordedEvent) -> Input?,
            execute: @Sendable @escaping (Input) async throws -> Void
        ) -> Self {
            let registration = Registration(dispatch: { record in
                guard Self._shouldDispatch(
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

        // Internal — pure filter-check used by the production dispatch closure
        // and by unit tests. Not part of the public API.
        internal static func _shouldDispatch(
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

    /// Transactional projection runner — every event triggers a single shared
    /// transaction; all registered projectors' writes commit or roll back
    /// together. Generic over `TransactionProvider`; `PostgresTransactionProvider`
    /// is the common case (see ReadModelPersistencePostgres convenience init).
    ///
    /// Shares retry/nack/cancellation semantics with `PersistentSubscriptionRunner`;
    /// the only difference is the per-event transaction scope.
    public final class TransactionalSubscriptionRunner<Provider: TransactionProvider>: Sendable {

        private let client: KurrentDBClient
        private let transactionProvider: Provider
        private let stream: String
        private let groupName: String
        private let retryPolicy: any RetryPolicy
        private let logger: Logger

        // Registrations: closure captures projector + storeFactory + extractInput;
        // signature is (RecordedEvent, Provider.Transaction) async throws -> Void.
        private let _registrations = Mutex<[TransactionalRegistration<Provider.Transaction>]>([])

        public init(
            client: KurrentDBClient,
            transactionProvider: Provider,
            stream: String,
            groupName: String,
            retryPolicy: any RetryPolicy = MaxRetriesPolicy(max: 5),
            logger: Logger = Logger(label: "KurrentProjection.TransactionalSubscriptionRunner")
        ) {
            self.client = client
            self.transactionProvider = transactionProvider
            self.stream = stream
            self.groupName = groupName
            self.retryPolicy = retryPolicy
            self.logger = logger
        }

        /// Register a projector with a per-event tx-bound store factory.
        ///
        /// `storeFactory` is called once per event with the runner's transaction;
        /// it returns a tx-bound store. The runner internally inlines fetch +
        /// apply + save (no `StatefulEventSourcingProjector` exposed to callers).
        ///
        /// Pass an `eventFilter` to short-circuit dispatch for event types this
        /// projector doesn't care about — no `extractInput`, no fetch, no apply.
        @discardableResult
        public func register<Projector: EventSourcingProjector & Sendable, Store: TransactionalReadModelStore>(
            projector: Projector,
            storeFactory: @Sendable @escaping (Provider.Transaction) -> Store,
            eventFilter: (any EventTypeFilter)? = nil,
            extractInput: @Sendable @escaping (RecordedEvent) -> Projector.Input?
        ) -> Self
        where Store.Model == Projector.ReadModelType,
              Store.Transaction == Provider.Transaction,
              Store.Model.ID == String,
              Projector.Input: Sendable
        {
            let registration = TransactionalRegistration<Provider.Transaction>(dispatch: { record, tx in
                guard Self._shouldDispatchTx(eventType: record.eventType, filter: eventFilter) else { return }
                guard let input = extractInput(record) else { return }
                let store = storeFactory(tx)

                // Incremental fold: fetch from stored revision, apply, save.
                if let stored = try await store.fetch(byId: input.id, in: tx) {
                    // Incremental path: only events newer than stored revision
                    guard let result = try await projector.coordinator.fetchEvents(
                        byId: input.id, afterRevision: stored.revision
                    ) else { return }
                    if result.events.isEmpty { return }
                    var readModel = stored.readModel
                    try projector.apply(readModel: &readModel, events: result.events)
                    try await store.save(readModel: readModel, revision: result.latestRevision, in: tx)
                } else {
                    // Full replay path
                    guard let result = try await projector.coordinator.fetchEvents(byId: input.id) else { return }
                    guard !result.events.isEmpty else { return }
                    guard var readModel = try projector.buildReadModel(input: input) else { return }
                    try projector.apply(readModel: &readModel, events: result.events)
                    try await store.save(readModel: readModel, revision: result.latestRevision, in: tx)
                }
            })
            _registrations.withLock { $0.append(registration) }
            return self
        }

        // Test-only — used by unit tests to verify register chaining.
        // Internal access; not part of the public API.
        internal var _registrationCountForTesting: Int {
            _registrations.withLock { $0.count }
        }

        // Internal — pure filter-check used by the production dispatch closure
        // and by unit tests. Not part of the public API.
        internal static func _shouldDispatchTx(
            eventType: String,
            filter: (any EventTypeFilter)?
        ) -> Bool {
            guard let filter else { return true }
            return filter.handles(eventType: eventType)
        }

        /// Subscribe to the persistent subscription and dispatch each event to all
        /// registered projectors inside a single transaction. Commits on full
        /// success, rolls back on any failure (then runs through `RetryPolicy`).
        ///
        /// Cancellation is observed between events, not mid-dispatch.
        public func run() async throws {
            let subscription = try await client
                .persistentSubscriptions(stream: stream, group: groupName)
                .subscribe()

            do {
                for try await result in subscription.events {
                    if Task.isCancelled { return }

                    let record = result.event.record
                    do {
                        try await transactionProvider.withTransaction { tx in
                            try await self.dispatch(record: record, transaction: tx)
                        }
                        try await subscription.ack(readEvents: result.event)
                    } catch {
                        try await handleFailure(error: error, result: result, subscription: subscription)
                    }
                }
            } catch is CancellationError {
                return
            }
        }

        /// Dispatch a single recorded event to all registered projectors within
        /// the supplied transaction. Throws if any projector throws — TaskGroup
        /// cancels remaining children, the throw bubbles to `withTransaction`
        /// which rolls back.
        internal func dispatch(record: RecordedEvent, transaction tx: Provider.Transaction) async throws {
            let snapshot = _registrations.withLock { $0 }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for registration in snapshot {
                    group.addTask {
                        try await registration.dispatch(record, tx)
                    }
                }
                try await group.waitForAll()
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
    }

    fileprivate struct TransactionalRegistration<Transaction: Sendable>: Sendable {
        let dispatch: @Sendable (RecordedEvent, Transaction) async throws -> Void
    }
}
