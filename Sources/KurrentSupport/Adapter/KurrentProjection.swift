//
//  KurrentProjection.swift
//  KurrentSupport
//
//  Phase 1 — Persistent Subscription Runner.
//  See spec: docs/superpowers/specs/2026-04-28-kurrent-projection-runner-design.md
//

import KurrentDB
import Logging
import Foundation
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
///   on failure. `ServiceGroup` (Swift Service Lifecycle) does not restart failed
///   services, so wrap `run()` in a restart loop with backoff or let the process exit and
///   have the process supervisor restart it.
///
/// ## System projection streams
///
/// With the default `.ensure` setup the runner creates the group with `resolveLink = true`,
/// so this section only applies to `.manual`. When subscribing to a system projection
/// stream like `$ce-<Category>` or `$et-<Type>`, you must create the persistent
/// subscription with `resolveLink = true`. Otherwise the
/// event delivered to your `extractInput` closure will reference the system
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
/// ## Test doubles
///
/// Both runners accept `client: any EventStoreClient` in addition to a concrete
/// `KurrentDBClient` — pass an `InMemoryEventStoreClient` (see the
/// `KurrentSupportInMemory` target) to exercise `run()`/`register()` in unit tests
/// with no live KurrentDB instance.
///
/// ## Reacting to committed writes
///
/// Both runners accept opt-in after-commit hooks via `onCommitted(_:)`; see
/// ``KurrentProjection/CommittedProjection`` for when they fire and what they see.
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

    /// How a runner treats its persistent subscription group.
    public enum SubscriptionSetup: Sendable {
        /// Create the group before subscribing if it doesn't exist, and recreate it
        /// when it disappears (KurrentDB recreated, group deleted). On disappearance
        /// `run()` recreates the group and then throws
        /// `EventStoreClientError.subscriptionGroupNotFound`; the caller must call `run()`
        /// again (restart loop with backoff, or let the process exit and be restarted by its
        /// supervisor) to resubscribe. With `startFrom: .start` the recreated group replays
        /// everything; the revision cursor makes that a no-op.
        ///
        /// This assumes the event data survived. If KurrentDB was recreated empty (or the
        /// event history was otherwise reset), stored revisions are ahead of the new
        /// streams and the replay would be skipped — run `KurrentProjection.rebuild`
        /// instead of relying on auto-recreation.
        case ensure(PersistentSubscriptionSettings)
        /// The caller creates and maintains the group (behavior before 1.4.0-beta.12).
        case manual
    }

    /// Shared by both runners: ensure the group, run `consume`, and recreate the group
    /// if it went missing.
    static func withSubscriptionGroup(
        client: any EventStoreClient,
        stream: String,
        group: String,
        setup: SubscriptionSetup,
        logger: Logger,
        consume: () async throws -> Void
    ) async throws {
        guard case let .ensure(settings) = setup else {
            try await consume()
            return
        }
        try await client.ensurePersistentSubscription(stream: stream, group: group, settings: settings)
        do {
            try await consume()
        } catch let error as EventStoreClientError {
            guard case .subscriptionGroupNotFound = error else { throw error }
            logger.warning("\(stream)/\(group): subscription group is missing — recreating it (startFrom: \(settings.startFrom))")
            do {
                try await client.ensurePersistentSubscription(stream: stream, group: group, settings: settings)
            } catch let ensureError {
                logger.error("\(stream)/\(group): recreating the subscription group failed: \(ensureError)")
            }
            throw error
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

    /// What one subscription delivery made durable, handed to the hooks registered with
    /// `onCommitted(_:)` on ``PersistentSubscriptionRunner`` and ``TransactionalSubscriptionRunner``.
    ///
    /// ## When a hook fires
    ///
    /// - ``TransactionalSubscriptionRunner``: after `withTransaction` returned, i.e. the
    ///   delivery's transaction committed. Never on rollback.
    /// - ``PersistentSubscriptionRunner``: after every registration finished without
    ///   throwing, i.e. every store save of the delivery succeeded.
    ///
    /// In both runners a hook does not fire when the delivery failed (projector or store
    /// threw — it is nacked instead), or when no registration handled it (every
    /// registration's `eventFilter` rejected it or its `extractInput` returned `nil`).
    /// It is queued right after the commit, before the ack, and fires whether or not the
    /// ack then succeeds: the write is durable either way. If the ack fails, KurrentDB
    /// redelivers the event and the hook may see it again (usually with no
    /// ``writtenReadModels``, since the fold has nothing new).
    ///
    /// ## Isolation
    ///
    /// Hooks never run on the subscription loop. Each runner hands committed deliveries
    /// to one background task (started by `run()` only when a hook is registered) that
    /// calls the hooks one at a time, in registration order, for one delivery after
    /// another in commit order. So a slow hook delays later *hooks*, never the next
    /// delivery, its commit or its ack, and a hook can't cause a nack or a redelivery.
    /// The hand-off queue is unbounded: a hook that is permanently slower than the
    /// subscription grows it without limit — move heavy work onto your own queue.
    /// When `run()` returns, already queued deliveries are still delivered to the hooks.
    ///
    /// ## Single process only
    ///
    /// A hook fires only in the process that handled the delivery. Other processes
    /// (another replica of the same consumer group, a web tier holding WebSockets) are
    /// not told; fanning out across processes (e.g. Postgres `NOTIFY`, a message bus) is
    /// the application's job.
    public struct CommittedProjection: Sendable, Equatable {

        /// One read model row saved while handling the delivery.
        public struct WrittenReadModel: Sendable, Hashable {
            /// The model's `ReadModel.readModelTypeName`.
            public let readModelTypeName: String
            public let id: String

            public init(readModelTypeName: String, id: String) {
                self.readModelTypeName = readModelTypeName
                self.id = id
            }
        }

        /// Id of the source event.
        public let eventId: UUID
        /// Type of the source event.
        public let eventType: String
        /// Stream the source event was originally appended to, e.g. `"Order-42"`.
        public let streamName: String
        /// The source event's revision, as reported by `RecordedEventLike.revision`.
        public let revision: UInt64
        /// Read models saved for this delivery, in registration order. Lists only
        /// `register(projector:…)` registrations that actually saved — not those whose
        /// fold found no new events — and never closure registrations
        /// (`register(eventFilter:extractInput:execute:)`), whose writes the runner can't see.
        public let writtenReadModels: [WrittenReadModel]

        /// The ids of ``writtenReadModels``.
        public var readModelIds: [String] { writtenReadModels.map(\.id) }

        public init(eventId: UUID, eventType: String, streamName: String, revision: UInt64, writtenReadModels: [WrittenReadModel]) {
            self.eventId = eventId
            self.eventType = eventType
            self.streamName = streamName
            self.revision = revision
            self.writtenReadModels = writtenReadModels
        }

        init(record: any RecordedEventLike, writtenReadModels: [WrittenReadModel]) {
            self.init(
                eventId: record.id, eventType: record.eventType, streamName: record.streamName,
                revision: record.revision, writtenReadModels: writtenReadModels
            )
        }
    }

    /// A hook registered with `onCommitted(_:)`. Non-throwing: handle your own errors.
    public typealias CommitHook = @Sendable (CommittedProjection) async -> Void

    /// Hands committed deliveries from the subscription loop to one background task that
    /// runs the hooks in order. Only created when at least one hook is registered.
    struct CommitNotifier: Sendable {
        private let continuation: AsyncStream<CommittedProjection>.Continuation

        static func start(hooks: [CommitHook]) -> CommitNotifier? {
            guard !hooks.isEmpty else { return nil }
            let (stream, continuation) = AsyncStream.makeStream(of: CommittedProjection.self)
            Task {
                for await committed in stream {
                    for hook in hooks { await hook(committed) }
                }
            }
            return CommitNotifier(continuation: continuation)
        }

        func notify(_ committed: CommittedProjection) { continuation.yield(committed) }
        func finish() { continuation.finish() }
    }

    /// `nil` = no registration handled the event; otherwise the read models saved.
    typealias DispatchOutcome = [CommittedProjection.WrittenReadModel]?

    public final class PersistentSubscriptionRunner: Sendable {

        private let client: any EventStoreClient
        private let stream: String
        private let groupName: String
        private let retryPolicy: any RetryPolicy
        private let subscriptionSetup: SubscriptionSetup
        private let logger: Logger

        // Registrations are appended via `register` (chainable, sync) and read by `run()`.
        // Convention: register before run. Lock is defensive, not for concurrent register/run.
        private let _registrations = Mutex<[Registration]>([])
        private let _commitHooks = Mutex<[CommitHook]>([])

        public init(
            client: any EventStoreClient,
            stream: String,
            groupName: String,
            retryPolicy: any RetryPolicy = MaxRetriesPolicy(max: 5),
            subscriptionSetup: SubscriptionSetup = .ensure(.init()),
            logger: Logger = Logger(label: "KurrentProjection.PersistentSubscriptionRunner")
        ) {
            self.client = client
            self.stream = stream
            self.groupName = groupName
            self.retryPolicy = retryPolicy
            self.subscriptionSetup = subscriptionSetup
            self.logger = logger
        }

        /// Convenience initializer for the common case of a real KurrentDB connection.
        /// Wraps `client` in a `LiveEventStoreClient` internally.
        public convenience init(
            client: KurrentDBClient,
            stream: String,
            groupName: String,
            retryPolicy: any RetryPolicy = MaxRetriesPolicy(max: 5),
            subscriptionSetup: SubscriptionSetup = .ensure(.init()),
            logger: Logger = Logger(label: "KurrentProjection.PersistentSubscriptionRunner")
        ) {
            self.init(
                client: LiveEventStoreClient(client: client),
                stream: stream,
                groupName: groupName,
                retryPolicy: retryPolicy,
                subscriptionSetup: subscriptionSetup,
                logger: logger
            )
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
            extractInput: @Sendable @escaping (any RecordedEventLike) -> Projector.Input?
        ) -> Self
        where Store.Model == Projector.ReadModelType,
              Store.Model.ID == String,
              Projector.Input: Sendable
        {
            let registration = Registration(dispatch: { record in
                guard Self._shouldDispatch(eventType: record.eventType, filter: eventFilter) else { return nil }
                guard let input = extractInput(record) else { return nil }

                // Incremental fold: fetch from stored revision, apply, save.
                let readModel: Store.Model
                if let stored = try await store.fetch(byId: input.id) {
                    guard let result = try await projector.store.fetchEvents(
                        byId: input.id, afterRevision: stored.revision
                    ) else { return [] }
                    if result.events.isEmpty { return [] }
                    var folded = stored.readModel
                    try projector.apply(readModel: &folded, events: result.events)
                    try await store.save(readModel: folded, revision: result.latestRevision)
                    readModel = folded
                } else {
                    guard let result = try await projector.store.fetchEvents(byId: input.id) else { return [] }
                    guard !result.events.isEmpty else { return [] }
                    guard var folded = try projector.buildReadModel(input: input) else { return [] }
                    try projector.apply(readModel: &folded, events: result.events)
                    try await store.save(readModel: folded, revision: result.latestRevision)
                    readModel = folded
                }
                return [.init(readModelTypeName: Store.Model.readModelTypeName, id: readModel.id)]
            })
            _registrations.withLock { $0.append(registration) }
            return self
        }

        @discardableResult
        public func register<Input: Sendable>(
            eventFilter: (any EventTypeFilter)? = nil,
            extractInput: @Sendable @escaping (any RecordedEventLike) -> Input?,
            execute: @Sendable @escaping (Input) async throws -> Void
        ) -> Self {
            let registration = Registration(dispatch: { record in
                guard Self._shouldDispatch(
                    eventType: record.eventType, filter: eventFilter
                ) else { return nil }
                guard let input = extractInput(record) else { return nil }
                try await execute(input)
                return []
            })
            _registrations.withLock { $0.append(registration) }
            return self
        }

        /// Add a hook called after each delivery's store saves succeeded.
        ///
        /// Opt-in; with no hook registered `run()` starts no extra task. Register hooks
        /// before calling `run()`; several hooks run one after another in registration
        /// order. See ``KurrentProjection/CommittedProjection`` for exactly when a hook
        /// fires, its ordering and isolation guarantees, and the single-process caveat.
        @discardableResult
        public func onCommitted(_ hook: @escaping CommitHook) -> Self {
            _commitHooks.withLock { $0.append(hook) }
            return self
        }

        /// Dispatch a single recorded event to all registered projectors in parallel.
        /// Throws if any projector throws (TaskGroup semantics — others are cancelled).
        /// Returns `nil` if no registration handled the event, otherwise the read models
        /// saved, in registration order.
        @discardableResult
        internal func dispatch(record: any RecordedEventLike) async throws -> DispatchOutcome {
            let snapshot = _registrations.withLock { $0 }
            let outcomes = try await withThrowingTaskGroup(of: (Int, DispatchOutcome).self) { group in
                for (index, registration) in snapshot.enumerated() {
                    group.addTask {
                        (index, try await registration.dispatch(record))
                    }
                }
                var outcomes = [DispatchOutcome](repeating: nil, count: snapshot.count)
                for try await (index, outcome) in group { outcomes[index] = outcome }
                return outcomes
            }
            let handled = outcomes.compactMap { $0 }
            return handled.isEmpty ? nil : handled.flatMap { $0 }
        }

        /// Subscribe to the persistent subscription and dispatch each event to all
        /// registered projectors in parallel. Acks on success.
        ///
        /// Returns when the parent `Task` is cancelled. Throws on subscription
        /// connection failure (no auto-reconnect — the caller must call `run()` again,
        /// e.g. in a restart loop with backoff).
        ///
        /// With the default `.ensure` setup the group is created first and recreated if it
        /// goes missing — see ``KurrentProjection/SubscriptionSetup``.
        ///
        /// Cancellation is observed between events, not mid-dispatch — once an event
        /// enters `dispatch(record:)` it runs to completion (or until the registered
        /// closures themselves observe `Task.isCancelled`).
        ///
        /// Hooks added with ``onCommitted(_:)`` are queued after a delivery's saves
        /// succeeded and before its ack, and run off the subscription loop.
        public func run() async throws {
            let notifier = CommitNotifier.start(hooks: _commitHooks.withLock { $0 })
            defer { notifier?.finish() }
            try await KurrentProjection.withSubscriptionGroup(
                client: client, stream: stream, group: groupName,
                setup: subscriptionSetup, logger: logger
            ) {
                let subscription = try await client.subscribePersistent(stream: stream, group: groupName)
                for try await delivery in subscription.events {
                    if Task.isCancelled { return }
                    do {
                        let written = try await dispatch(record: delivery.event)
                        if let notifier, let written {
                            notifier.notify(CommittedProjection(record: delivery.event, writtenReadModels: written))
                        }
                        try await subscription.ack([delivery])
                    } catch {
                        try await handleFailure(error: error, delivery: delivery, subscription: subscription)
                    }
                }
            }
        }

        private func handleFailure(
            error: any Error,
            delivery: SubscriptionDelivery,
            subscription: any PersistentSubscriptionSession
        ) async throws {
            let action = retryPolicy.decide(error: error, retryCount: delivery.retryCount)
            do {
                try await subscription.nack([delivery], action: action, reason: "\(error)")
            } catch let nackError {
                logger.error("nack failed for event \(delivery.event.id): \(nackError)")
                // Continue — nack failure should not crash the run loop.
            }

            // .stop is honored even if the nack call above failed — the policy's
            // decision to stop the runner is independent of whether the server
            // received the nack message.
            if case .stop = action {
                throw RunnerStopped(reason: "RetryPolicy returned .stop after \(delivery.retryCount) retries: \(error)")
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
        let dispatch: @Sendable (any RecordedEventLike) async throws -> DispatchOutcome
    }

    /// Transactional projection runner — every event triggers a single shared
    /// transaction; all registered projectors' writes commit or roll back
    /// together. Generic over `TransactionProvider`; `PostgresTransactionProvider`
    /// is the common case (see ReadModelPersistencePostgres convenience init).
    ///
    /// Shares retry/nack/cancellation semantics with `PersistentSubscriptionRunner`;
    /// the only difference is the per-event transaction scope.
    public final class TransactionalSubscriptionRunner<Provider: TransactionProvider>: Sendable {

        private let client: any EventStoreClient
        private let transactionProvider: Provider
        private let stream: String
        private let groupName: String
        private let retryPolicy: any RetryPolicy
        private let subscriptionSetup: SubscriptionSetup
        private let logger: Logger

        // Registrations: closure captures projector + storeFactory + extractInput;
        // signature is (any RecordedEventLike, Provider.Transaction) async throws -> Void.
        private let _registrations = Mutex<[TransactionalRegistration<Provider.Transaction>]>([])
        private let _commitHooks = Mutex<[CommitHook]>([])

        public init(
            client: any EventStoreClient,
            transactionProvider: Provider,
            stream: String,
            groupName: String,
            retryPolicy: any RetryPolicy = MaxRetriesPolicy(max: 5),
            subscriptionSetup: SubscriptionSetup = .ensure(.init()),
            logger: Logger = Logger(label: "KurrentProjection.TransactionalSubscriptionRunner")
        ) {
            self.client = client
            self.transactionProvider = transactionProvider
            self.stream = stream
            self.groupName = groupName
            self.retryPolicy = retryPolicy
            self.subscriptionSetup = subscriptionSetup
            self.logger = logger
        }

        /// Convenience initializer for the common case of a real KurrentDB connection.
        /// Wraps `client` in a `LiveEventStoreClient` internally.
        public convenience init(
            client: KurrentDBClient,
            transactionProvider: Provider,
            stream: String,
            groupName: String,
            retryPolicy: any RetryPolicy = MaxRetriesPolicy(max: 5),
            subscriptionSetup: SubscriptionSetup = .ensure(.init()),
            logger: Logger = Logger(label: "KurrentProjection.TransactionalSubscriptionRunner")
        ) {
            self.init(
                client: LiveEventStoreClient(client: client),
                transactionProvider: transactionProvider,
                stream: stream,
                groupName: groupName,
                retryPolicy: retryPolicy,
                subscriptionSetup: subscriptionSetup,
                logger: logger
            )
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
            extractInput: @Sendable @escaping (any RecordedEventLike) -> Projector.Input?
        ) -> Self
        where Store.Model == Projector.ReadModelType,
              Store.Transaction == Provider.Transaction,
              Store.Model.ID == String,
              Projector.Input: Sendable
        {
            let registration = TransactionalRegistration<Provider.Transaction>(dispatch: { record, tx in
                guard Self._shouldDispatchTx(eventType: record.eventType, filter: eventFilter) else { return nil }
                guard let input = extractInput(record) else { return nil }
                let store = storeFactory(tx)

                // Incremental fold: fetch from stored revision, apply, save.
                let readModel: Store.Model
                if let stored = try await store.fetch(byId: input.id, in: tx) {
                    // Incremental path: only events newer than stored revision
                    guard let result = try await projector.store.fetchEvents(
                        byId: input.id, afterRevision: stored.revision
                    ) else { return [] }
                    if result.events.isEmpty { return [] }
                    var folded = stored.readModel
                    try projector.apply(readModel: &folded, events: result.events)
                    try await store.save(readModel: folded, revision: result.latestRevision, in: tx)
                    readModel = folded
                } else {
                    // Full replay path
                    guard let result = try await projector.store.fetchEvents(byId: input.id) else { return [] }
                    guard !result.events.isEmpty else { return [] }
                    guard var folded = try projector.buildReadModel(input: input) else { return [] }
                    try projector.apply(readModel: &folded, events: result.events)
                    try await store.save(readModel: folded, revision: result.latestRevision, in: tx)
                    readModel = folded
                }
                return [.init(readModelTypeName: Store.Model.readModelTypeName, id: readModel.id)]
            })
            _registrations.withLock { $0.append(registration) }
            return self
        }

        /// Add a hook called after each delivery's transaction committed.
        ///
        /// Opt-in; with no hook registered `run()` starts no extra task. Register hooks
        /// before calling `run()`; several hooks run one after another in registration
        /// order. Never called for a rolled-back transaction. See
        /// ``KurrentProjection/CommittedProjection`` for exactly when a hook fires, its
        /// ordering and isolation guarantees, and the single-process caveat.
        @discardableResult
        public func onCommitted(_ hook: @escaping CommitHook) -> Self {
            _commitHooks.withLock { $0.append(hook) }
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
        ///
        /// Hooks added with ``onCommitted(_:)`` are queued after the commit and before
        /// the ack, and run off the subscription loop.
        public func run() async throws {
            let notifier = CommitNotifier.start(hooks: _commitHooks.withLock { $0 })
            defer { notifier?.finish() }
            do {
                try await KurrentProjection.withSubscriptionGroup(
                    client: client, stream: stream, group: groupName,
                    setup: subscriptionSetup, logger: logger
                ) {
                    let subscription = try await client.subscribePersistent(stream: stream, group: groupName)
                    for try await delivery in subscription.events {
                        if Task.isCancelled { return }
                        do {
                            let written = try await transactionProvider.withTransaction { tx in
                                try await self.dispatch(record: delivery.event, transaction: tx)
                            }
                            if let notifier, let written {
                                notifier.notify(CommittedProjection(record: delivery.event, writtenReadModels: written))
                            }
                            try await subscription.ack([delivery])
                        } catch {
                            try await handleFailure(error: error, delivery: delivery, subscription: subscription)
                        }
                    }
                }
            } catch is CancellationError {
                return
            }
        }

        /// Dispatch a single recorded event to every registered projector, one after
        /// another in registration order, within the supplied transaction. Sequential
        /// on purpose: all projectors share the transaction's single connection.
        /// The first throw stops the rest and bubbles to `withTransaction`, which
        /// rolls back. Returns `nil` if no registration handled the event, otherwise the
        /// read models saved, in registration order.
        @discardableResult
        internal func dispatch(record: any RecordedEventLike, transaction tx: Provider.Transaction) async throws -> DispatchOutcome {
            let snapshot = _registrations.withLock { $0 }
            var written: DispatchOutcome = nil
            for registration in snapshot {
                if let saved = try await registration.dispatch(record, tx) {
                    written = (written ?? []) + saved
                }
            }
            return written
        }

        private func handleFailure(
            error: any Error,
            delivery: SubscriptionDelivery,
            subscription: any PersistentSubscriptionSession
        ) async throws {
            let action = retryPolicy.decide(error: error, retryCount: delivery.retryCount)
            do {
                try await subscription.nack([delivery], action: action, reason: "\(error)")
            } catch let nackError {
                logger.error("nack failed for event \(delivery.event.id): \(nackError)")
                // Continue — nack failure should not crash the run loop.
            }

            // .stop is honored even if the nack call above failed — the policy's
            // decision to stop the runner is independent of whether the server
            // received the nack message.
            if case .stop = action {
                throw RunnerStopped(reason: "RetryPolicy returned .stop after \(delivery.retryCount) retries: \(error)")
            }
        }
    }

    fileprivate struct TransactionalRegistration<Transaction: Sendable>: Sendable {
        let dispatch: @Sendable (any RecordedEventLike, Transaction) async throws -> DispatchOutcome
    }
}
