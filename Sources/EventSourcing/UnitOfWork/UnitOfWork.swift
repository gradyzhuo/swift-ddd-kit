//
//  UnitOfWork.swift
//  DDDKit
//

import DDDCore
import Foundation
import Synchronization

/// Holds the scope of the running task. Mirrors `_EventMetadataStorage`.
private enum _UnitOfWorkStorage {
    @TaskLocal static var current: UnitOfWork?
}

/// Runs `body` as one unit of work: writes that participating stores make inside it
/// are collected and committed together once `body` returns; when `body` throws,
/// they are discarded and the error is rethrown.
///
/// The end of the scope, in order:
/// 1. `body` returns or throws, and the scope closes. From then on
///    ``UnitOfWork/backend(_:identity:make:)``, ``UnitOfWork/fail(_:)`` and
///    ``UnitOfWork/onCommitted(_:)`` throw `operationNotAllow`, including from a
///    `Task` started inside `body`, which still sees this scope as
///    ``UnitOfWork/current``.
/// 2. `body` threw → that error is rethrown; nothing is committed and no hook runs.
/// 3. The scope was failed (``UnitOfWork/fail(_:)``) → nothing is committed, no hook
///    runs, and `DDDError.operationNotAllow(operation: "commit", ...)` is thrown with
///    the first cause in `userInfos["cause"]`.
/// 4. Otherwise the backend, if any store registered one, commits. A commit error is
///    rethrown and no hook runs. After `commitConflict` or `streamPurged` nothing was
///    written. After any other commit error (transport, `atomicAppendUnsupported`, a
///    server without AppendRecords) the writes may have landed, for example when the
///    response was lost after the server committed: read the streams before running
///    the block again.
/// 5. The ``UnitOfWork/onCommitted(_:)`` hooks run in registration order, each
///    awaited, with ``UnitOfWork/current`` `nil`. A hook error stops the later hooks
///    and is rethrown, but the commit has already happened.
///
/// Scopes do not nest: called inside a scope, this throws
/// `DDDError.operationNotAllow(operation: "withUnitOfWork", ...)` without running
/// `body` and leaves the outer scope untouched.
@discardableResult
public func withUnitOfWork<R>(_ body: (UnitOfWork) async throws -> R) async throws -> R {
    if let current = UnitOfWork.current {
        throw DDDError.operationNotAllow(
            operation: "withUnitOfWork",
            reason: "already inside unit of work \(current.id)"
        )
    }
    let work = UnitOfWork()
    var ending: UnitOfWork.Ending?
    let result = try await _UnitOfWorkStorage.$current.withValue(work) {
        // Closes the scope whether `body` returned or threw. `close()` also takes the
        // backend and the hooks out of `work`, so a hook that captures `work` keeps
        // neither alive; when `body` threw, they are dropped with `ending`.
        defer { ending = work.close() }
        return try await body(work)
    }
    guard let ending else {
        preconditionFailure("unit of work \(work.id) did not close when its body returned")
    }
    // Outside the TaskLocal from here on: hooks see `UnitOfWork.current == nil`.
    try await ending.commitAndRunHooks()
    return result
}

/// The scope ``withUnitOfWork(_:)`` opens; the running task reaches it through
/// ``current``.
public final class UnitOfWork: Sendable {
    private struct State {
        var backend: (any UnitOfWorkBackend)?
        var backendIdentity: ObjectIdentifier?
        var failure: (any Error)?
        var hooks: [@Sendable () async throws -> Void] = []
        var closed = false
    }

    /// Identifies this scope, e.g. to correlate logs. Differs between scopes.
    public let id: UUID

    private let state = Mutex(State())

    fileprivate init() {
        id = UUID()
    }

    /// The scope the running task is in, or `nil` outside any scope.
    ///
    /// A `Task` started inside the scope keeps seeing it after the scope ended; the
    /// scope then rejects every change. `Task.detached`, and code that does not run in
    /// the scope's task tree (a NIO future callback, a `DispatchQueue` block), see `nil`:
    /// a `save` there writes at once and is not part of the commit.
    public static var current: UnitOfWork? {
        _UnitOfWorkStorage.current
    }

    /// True once ``fail(_:)`` was called, by the caller or by the framework.
    public var isFailed: Bool {
        state.withLock { $0.failure != nil }
    }

    /// The first cause passed to ``fail(_:)``.
    package var failure: (any Error)? {
        state.withLock { $0.failure }
    }

    /// Marks the scope failed without throwing: `body` may go on and return normally,
    /// but nothing is committed and ``withUnitOfWork(_:)`` throws
    /// `operationNotAllow(operation: "commit", ...)` carrying the first cause.
    ///
    /// - Throws: `DDDError.operationNotAllow` once the scope has ended.
    public func fail(_ error: any Error) throws {
        try state.withLock { state in
            guard !state.closed else { throw ended(operation: "fail") }
            if state.failure == nil {
                state.failure = error
            }
        }
    }

    /// Registers `action` to run after a successful commit (a scope without a backend
    /// counts as committed). Hooks run in registration order, one at a time, before
    /// ``withUnitOfWork(_:)`` returns, with ``current`` `nil`: a repository save inside
    /// a hook writes straight to the store, outside this unit of work. A throwing hook
    /// stops the later ones and its error is rethrown, although the commit stands.
    ///
    /// - Throws: `DDDError.operationNotAllow` once the scope has ended.
    public func onCommitted(_ action: @escaping @Sendable () async throws -> Void) throws {
        try state.withLock { state in
            guard !state.closed else { throw ended(operation: "onCommitted") }
            state.hooks.append(action)
        }
    }

    /// For store implementations: the backend this scope commits through, created by
    /// `make` on first use. Looking up, creating and storing happen under one lock, so
    /// concurrent first callers get the same instance.
    ///
    /// - Parameters:
    ///   - type: The backend type the store commits through.
    ///   - identity: What the backend writes to, e.g. the client's identity. Stores
    ///     that pass the same type and identity share one backend.
    ///   - make: Creates the backend when the scope has none yet. It runs while the
    ///     scope's lock is held, so it must not call back into this scope.
    /// - Throws: `DDDError.operationNotAllow` when the scope already has a backend of
    ///   another type or identity (a unit of work commits through exactly one), or
    ///   once the scope has ended.
    public func backend<B: UnitOfWorkBackend>(
        _ type: B.Type,
        identity: ObjectIdentifier,
        make: () -> B
    ) throws -> B {
        try state.withLock { state in
            guard !state.closed else { throw ended(operation: "backend") }
            guard let stored = state.backend else {
                let created = make()
                state.backend = created
                state.backendIdentity = identity
                return created
            }
            guard Swift.type(of: stored) == B.self,
                  state.backendIdentity == identity,
                  let existing = stored as? B
            else {
                throw DDDError.operationNotAllow(
                    operation: "backend",
                    reason: "a unit of work commits through exactly one backend"
                )
            }
            return existing
        }
    }

    /// For store implementations' read paths: the backend this scope commits through, if
    /// the scope is open and its backend has exactly type `B` and was registered for
    /// `identity`; `nil` when there is none yet, it has another type or identity, or the
    /// scope has ended. Never creates a backend and never throws, so a read leaves the
    /// scope as it found it. Writes use ``backend(_:identity:make:)``.
    package func existingBackend<B: UnitOfWorkBackend>(_ type: B.Type, identity: ObjectIdentifier) -> B? {
        state.withLock { state in
            guard !state.closed,
                  let stored = state.backend,
                  Swift.type(of: stored) == B.self,
                  state.backendIdentity == identity
            else {
                return nil
            }
            return stored as? B
        }
    }

    /// Runs `operation`; when it throws, fails the current scope with that error (if
    /// there is one and it is still open) and rethrows the original error. A plain
    /// pass-through outside a scope.
    package static func failingCurrentOnError<R>(
        _ operation: () async throws -> R
    ) async rethrows -> R {
        do {
            return try await operation()
        } catch {
            try? current?.fail(error)
            throw error
        }
    }

    /// What is left to do once the scope closed: throw for `failure` if the scope was
    /// failed, otherwise commit through `backend` and run `hooks`.
    fileprivate struct Ending {
        let backend: (any UnitOfWorkBackend)?
        let failure: (any Error)?
        let hooks: [@Sendable () async throws -> Void]

        /// Steps 3–5 of ``withUnitOfWork(_:)``.
        func commitAndRunHooks() async throws {
            if let failure {
                throw DDDError.operationNotAllow(
                    operation: "commit",
                    reason: "unit of work failed",
                    userInfos: ["cause": failure]
                )
            }
            try await backend?.commit()
            for hook in hooks {
                try await hook()
            }
        }
    }

    /// Closes the scope and moves the backend and the hooks out of it, in one lock.
    /// The scope keeps only `failure`, so ``isFailed`` still answers once it ended.
    fileprivate func close() -> Ending {
        state.withLock { state in
            state.closed = true
            let ending = Ending(backend: state.backend, failure: state.failure, hooks: state.hooks)
            state.backend = nil
            state.backendIdentity = nil
            state.hooks = []
            return ending
        }
    }

    private func ended(operation: String) -> DDDError {
        .operationNotAllow(operation: operation, reason: "unit of work \(id) already ended")
    }
}

/// Collects a unit of work's writes and sends them when the scope ends. Provided by
/// store implementations; a scope has at most one.
public protocol UnitOfWorkBackend: AnyObject, Sendable {
    /// Sends everything collected. Called at most once, after `body` returned
    /// normally on a scope that was not failed; never called when `body` threw or the
    /// scope was failed, in which case the backend is dropped with what it collected.
    func commit() async throws
}

/// Marks an `EventStore` that, inside a unit of work, hands its writes to the
/// scope's backend instead of writing directly.
public protocol UnitOfWorkParticipant {}
