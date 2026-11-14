// Tests/EventSourcingTests/UnitOfWorkTests.swift
import DDDCore
import Foundation
import Synchronization
import Testing
@testable import EventSourcing

private enum TestError: Error, Equatable {
    case first
    case second
    case commit
    case hook
}

/// Backend double: counts `commit()` calls and optionally throws from them.
private final class RecordingBackend: UnitOfWorkBackend {
    private let commits = Mutex(0)
    private let commitError: TestError?

    init(commitError: TestError? = nil) {
        self.commitError = commitError
    }

    var commitCount: Int { commits.withLock { $0 } }

    /// True once `commit()` was called; hooks read it to prove the commit ran first.
    var committed: Bool { commitCount > 0 }

    func commit() async throws {
        commits.withLock { $0 += 1 }
        if let commitError { throw commitError }
    }
}

private final class OtherBackend: UnitOfWorkBackend {
    func commit() async throws {}
}

/// A backend type with a subclass, to check that lookups want exactly the type asked for.
/// Stateless, so `@unchecked Sendable` is safe.
private class BaseBackend: UnitOfWorkBackend, @unchecked Sendable {
    func commit() async throws {}
}

private final class DerivedBackend: BaseBackend, @unchecked Sendable {}

/// Thread-safe append-only log the hooks and escaped tasks write into.
private final class Recorder<Value: Sendable>: Sendable {
    private let values = Mutex<[Value]>([])

    func append(_ value: Value) { values.withLock { $0.append(value) } }

    var all: [Value] { values.withLock { $0 } }
}

/// Stand-ins for two different clients' `identity`.
private enum ClientA {}
private enum ClientB {}
private let clientA = ObjectIdentifier(ClientA.self)
private let clientB = ObjectIdentifier(ClientB.self)

/// Registers `backend` as the scope's backend under `identity`.
@discardableResult
private func register(
    _ backend: RecordingBackend,
    in work: UnitOfWork,
    identity: ObjectIdentifier = clientA
) throws -> RecordingBackend {
    try work.backend(RecordingBackend.self, identity: identity) { backend }
}

/// The `operationNotAllow` error `body` throws for `operation`; records an issue and
/// returns nil when `body` throws something else or nothing.
private func captureOperationNotAllow(
    _ operation: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> Void
) async -> DDDError? {
    do {
        try await body()
        Issue.record("expected `\(operation)` to throw operationNotAllow", sourceLocation: sourceLocation)
        return nil
    } catch let error as DDDError {
        #expect(error.code == .aggregateOperationNotAllowed, sourceLocation: sourceLocation)
        #expect(error.userInfos["operation"] as? String == operation, sourceLocation: sourceLocation)
        return error
    } catch {
        Issue.record("expected operationNotAllow, got \(error)", sourceLocation: sourceLocation)
        return nil
    }
}

private func reason(of error: DDDError?) -> String? {
    error?.userInfos["reason"] as? String
}

/// How a scope ends.
enum ScopeEnding: CaseIterable, Sendable {
    /// `body` returns and the commit succeeds.
    case returns
    /// `body` throws `TestError.first`.
    case bodyThrows
    /// `body` calls `fail(TestError.first)`, then returns.
    case scopeFailed
    /// `body` returns and the backend's commit throws `TestError.commit`.
    case commitFails
}

/// A backend whose commit throws when the scope ends as `.commitFails`.
private func makeBackend(endingAs ending: ScopeEnding) -> RecordingBackend {
    RecordingBackend(commitError: ending == .commitFails ? .commit : nil)
}

/// Runs a scope whose body runs `prepare`, then ends the way `ending` says. Returns what
/// `withUnitOfWork` threw, or nil when it returned. For `.commitFails`, `prepare` must
/// register a backend from ``makeBackend(endingAs:)``.
private func runScope(
    endingAs ending: ScopeEnding,
    _ prepare: (UnitOfWork) throws -> Void
) async -> (any Error)? {
    do {
        try await withUnitOfWork { work in
            try prepare(work)
            switch ending {
            case .returns, .commitFails: break
            case .bodyThrows: throw TestError.first
            case .scopeFailed: try work.fail(TestError.first)
            }
        }
        return nil
    } catch {
        return error
    }
}

/// Checks that `error` is what `withUnitOfWork` throws for a scope that ended as `ending`.
private func expectError(
    _ error: (any Error)?,
    endingAs ending: ScopeEnding,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    switch ending {
    case .returns:
        #expect(error == nil, sourceLocation: sourceLocation)
    case .bodyThrows:
        #expect(error as? TestError == .first, sourceLocation: sourceLocation)
    case .scopeFailed:
        let dddError = error as? DDDError
        #expect(dddError?.userInfos["operation"] as? String == "commit", sourceLocation: sourceLocation)
        #expect(dddError?.userInfos["cause"] as? TestError == .first, sourceLocation: sourceLocation)
    case .commitFails:
        #expect(error as? TestError == .commit, sourceLocation: sourceLocation)
    }
}

@Suite("UnitOfWork")
struct UnitOfWorkTests {

    @Test("current is nil outside a scope and the scope inside it")
    func currentIsNilOutsideAndSetInside() async throws {
        #expect(UnitOfWork.current == nil)
        try await withUnitOfWork { work in
            #expect(UnitOfWork.current === work)
        }
        #expect(UnitOfWork.current == nil)
    }

    @Test("A nested withUnitOfWork throws without running its body; the outer scope still commits")
    func nestedCallThrowsAndOuterStillCommits() async throws {
        let backend = RecordingBackend()
        try await withUnitOfWork { outer in
            try register(backend, in: outer)
            let error = await captureOperationNotAllow("withUnitOfWork") {
                // `-> Void`: Swift 6.1 and 6.2 infer R from a lone `Issue.record` (it returns `Issue`).
                try await withUnitOfWork { _ -> Void in
                    Issue.record("the nested body must not run")
                }
            }
            #expect(reason(of: error) == "already inside unit of work \(outer.id)")
            #expect(UnitOfWork.current === outer)
            #expect(!outer.isFailed)
        }
        #expect(backend.commitCount == 1)
    }

    @Test("A body that throws is rethrown and nothing is committed")
    func bodyThrowDoesNotCommit() async throws {
        let backend = RecordingBackend()
        await #expect(throws: TestError.first) {
            try await withUnitOfWork { work in
                try register(backend, in: work)
                throw TestError.first
            }
        }
        #expect(backend.commitCount == 0)
    }

    @Test("fail then a normal return throws operationNotAllow with the cause and commits nothing")
    func failThenNormalReturnThrowsWithCause() async throws {
        let backend = RecordingBackend()
        let error = await captureOperationNotAllow("commit") {
            let output = try await withUnitOfWork { work in
                try register(backend, in: work)
                try work.fail(TestError.first)
                return "failed output"
            }
            Issue.record("withUnitOfWork returned \(output)")
        }
        #expect(reason(of: error) == "unit of work failed")
        #expect(error?.userInfos["cause"] as? TestError == .first)
        #expect(backend.commitCount == 0)
    }

    @Test("A second fail keeps the first cause")
    func secondFailKeepsFirstCause() async throws {
        let error = await captureOperationNotAllow("commit") {
            try await withUnitOfWork { work in
                try work.fail(TestError.first)
                try work.fail(TestError.second)
                #expect(work.failure as? TestError == .first)
            }
        }
        #expect(error?.userInfos["cause"] as? TestError == .first)
    }

    @Test("isFailed flips on fail, and on an error passing through failingCurrentOnError")
    func isFailedFlipsOnFail() async throws {
        _ = await captureOperationNotAllow("commit") {
            try await withUnitOfWork { work in
                #expect(!work.isFailed)
                try work.fail(TestError.first)
                #expect(work.isFailed)
            }
        }
        _ = await captureOperationNotAllow("commit") {
            try await withUnitOfWork { work in
                #expect(!work.isFailed)
                await #expect(throws: TestError.second) {
                    try await UnitOfWork.failingCurrentOnError { throw TestError.second }
                }
                #expect(work.isFailed)
                #expect(work.failure as? TestError == .second)
            }
        }
    }

    @Test("failingCurrentOnError is a pass-through outside a scope")
    func failingCurrentOnErrorPassesThroughOutsideScope() async throws {
        let value = await UnitOfWork.failingCurrentOnError { 42 }
        #expect(value == 42)
        await #expect(throws: TestError.first) {
            try await UnitOfWork.failingCurrentOnError { throw TestError.first }
        }
    }

    @Test("The backend is created once and shared by the same type and identity; another identity is rejected")
    func backendRegisteredOnceAndSharedByIdentity() async throws {
        let registered = RecordingBackend()
        try await withUnitOfWork { work in
            let first = try register(registered, in: work)
            let second = try work.backend(RecordingBackend.self, identity: clientA) {
                Issue.record("make must not run once a backend is stored")
                return RecordingBackend()
            }
            #expect(first === second)
            let error = await captureOperationNotAllow("backend") {
                _ = try work.backend(RecordingBackend.self, identity: clientB) { RecordingBackend() }
            }
            #expect(reason(of: error) == "a unit of work commits through exactly one backend")
        }
        #expect(registered.commitCount == 1)
    }

    @Test("A backend of another type under the same identity is rejected")
    func backendOfAnotherTypeIsRejected() async throws {
        try await withUnitOfWork { work in
            try register(RecordingBackend(), in: work)
            let error = await captureOperationNotAllow("backend") {
                _ = try work.backend(OtherBackend.self, identity: clientA) { OtherBackend() }
            }
            #expect(reason(of: error) == "a unit of work commits through exactly one backend")
        }
    }

    @Test("Two child tasks registering at once create a single backend")
    func concurrentFirstRegistrationMakesOneBackend() async throws {
        let makes = Recorder<Int>()
        try await withUnitOfWork { work in
            async let first = try work.backend(RecordingBackend.self, identity: clientA) {
                makes.append(1)
                return RecordingBackend()
            }
            async let second = try work.backend(RecordingBackend.self, identity: clientA) {
                makes.append(2)
                return RecordingBackend()
            }
            let (a, b) = try await (first, second)
            #expect(a === b)
        }
        #expect(makes.all.count == 1)
    }

    @Test("existingBackend never creates a backend: nil in a fresh scope, and a later backend call for another identity still succeeds")
    func existingBackendNeverCreates() async throws {
        let registered = RecordingBackend()
        try await withUnitOfWork { work in
            #expect(work.existingBackend(RecordingBackend.self, identity: clientA) == nil)
            #expect(work.existingBackend(RecordingBackend.self, identity: clientA) == nil)
            // The lookups pinned nothing to clientA, so the scope's backend may be clientB's.
            let pinned = try register(registered, in: work, identity: clientB)
            #expect(pinned === registered)
            #expect(!work.isFailed)
        }
        #expect(registered.commitCount == 1)
    }

    @Test("existingBackend returns the backend registered for the same type and identity")
    func existingBackendReturnsTheRegisteredOne() async throws {
        let registered = RecordingBackend()
        try await withUnitOfWork { work in
            try register(registered, in: work)
            #expect(work.existingBackend(RecordingBackend.self, identity: clientA) === registered)
        }
        #expect(registered.commitCount == 1)
    }

    @Test("existingBackend is nil for another type or identity, and leaves the scope and its backend as they were")
    func existingBackendIsNilForOtherTypeOrIdentity() async throws {
        let registered = RecordingBackend()
        try await withUnitOfWork { work in
            try register(registered, in: work)
            #expect(work.existingBackend(OtherBackend.self, identity: clientA) == nil)
            #expect(work.existingBackend(RecordingBackend.self, identity: clientB) == nil)
            #expect(!work.isFailed)
            #expect(work.existingBackend(RecordingBackend.self, identity: clientA) === registered)
        }
        #expect(registered.commitCount == 1)

        // A subclass of the type asked for is another type too.
        try await withUnitOfWork { work in
            let derived = try work.backend(DerivedBackend.self, identity: clientA) { DerivedBackend() }
            #expect(work.existingBackend(BaseBackend.self, identity: clientA) == nil)
            #expect(work.existingBackend(DerivedBackend.self, identity: clientA) === derived)
        }
    }

    @Test(
        "existingBackend is nil, without throwing, in an escaped task once the scope ended, however it ended",
        arguments: ScopeEnding.allCases
    )
    func existingBackendIsNilOnceEnded(ending: ScopeEnding) async throws {
        let backend = makeBackend(endingAs: ending)
        let (scopeEnded, endScope) = AsyncStream.makeStream(of: Void.self)
        var escaped: Task<RecordingBackend?, Never>?
        let error = await runScope(endingAs: ending) { work in
            try register(backend, in: work)
            #expect(work.existingBackend(RecordingBackend.self, identity: clientA) === backend)
            escaped = Task {
                for await _ in scopeEnded { break }
                return work.existingBackend(RecordingBackend.self, identity: clientA)
            }
        }
        // `withUnitOfWork` has returned or thrown; only now does the escaped task look.
        expectError(error, endingAs: ending)
        let task = try #require(escaped)
        endScope.yield()
        endScope.finish()
        #expect(await task.value == nil)
    }

    @Test("Hooks run in registration order, after the commit, before withUnitOfWork returns")
    func hooksRunInOrderAfterCommitBeforeReturn() async throws {
        let backend = RecordingBackend()
        let order = Recorder<Int>()
        let output = try await withUnitOfWork { work in
            try register(backend, in: work)
            try work.onCommitted {
                #expect(backend.committed)
                order.append(1)
            }
            try work.onCommitted {
                #expect(backend.committed)
                order.append(2)
            }
            #expect(order.all.isEmpty)
            return "output"
        }
        #expect(output == "output")
        #expect(order.all == [1, 2])
        #expect(backend.commitCount == 1)
    }

    @Test("Hooks run outside the scope: UnitOfWork.current is nil inside a hook")
    func hooksRunOutsideScope() async throws {
        let currentWasNil = Recorder<Bool>()
        try await withUnitOfWork { work in
            try work.onCommitted { currentWasNil.append(UnitOfWork.current == nil) }
        }
        #expect(currentWasNil.all == [true])
    }

    @Test("Hooks run when no backend was registered")
    func hooksRunWhenNoBackend() async throws {
        let runs = Recorder<Int>()
        try await withUnitOfWork { work in
            try work.onCommitted { runs.append(1) }
        }
        #expect(runs.all == [1])
    }

    @Test(
        "No hook runs when the body throws, the scope failed or the commit throws",
        arguments: [ScopeEnding.bodyThrows, .scopeFailed, .commitFails]
    )
    func hooksSkippedOnBodyThrowFailOrCommitError(ending: ScopeEnding) async throws {
        let backend = makeBackend(endingAs: ending)
        let runs = Recorder<Int>()
        let error = await runScope(endingAs: ending) { work in
            try register(backend, in: work)
            try work.onCommitted { runs.append(1) }
        }
        expectError(error, endingAs: ending)
        #expect(runs.all.isEmpty)
        #expect(backend.commitCount == (ending == .commitFails ? 1 : 0))
    }

    @Test("A throwing hook stops the later hooks and its error propagates after the commit")
    func hookErrorStopsLaterHooksAndPropagates() async throws {
        let backend = RecordingBackend()
        let runs = Recorder<Int>()
        await #expect(throws: TestError.hook) {
            try await withUnitOfWork { work in
                try register(backend, in: work)
                try work.onCommitted {
                    runs.append(1)
                    throw TestError.hook
                }
                try work.onCommitted { runs.append(2) }
            }
        }
        #expect(runs.all == [1])
        #expect(backend.commitCount == 1)
    }

    @Test("A hook registered after fail never runs")
    func hookAfterFailNeverRuns() async throws {
        let runs = Recorder<Int>()
        _ = await captureOperationNotAllow("commit") {
            try await withUnitOfWork { work in
                try work.fail(TestError.first)
                try work.onCommitted { runs.append(1) }
            }
        }
        #expect(runs.all.isEmpty)
    }

    @Test(
        "An escaped task still sees the closed scope, and backend, fail and onCommitted throw, however the scope ended",
        arguments: ScopeEnding.allCases
    )
    func closedScopeRejectsBackendFailAndHooks(ending: ScopeEnding) async throws {
        let backend = makeBackend(endingAs: ending)
        let hookRuns = Recorder<Int>()
        let (scopeEnded, endScope) = AsyncStream.makeStream(of: Void.self)
        var escapedScope: (work: UnitOfWork, task: Task<Void, Never>)?
        let error = await runScope(endingAs: ending) { work in
            try register(backend, in: work)
            escapedScope = (work, Task {
                for await _ in scopeEnded { break }
                #expect(UnitOfWork.current === work)
                let endedReason = "unit of work \(work.id) already ended"

                let backendError = await captureOperationNotAllow("backend") {
                    _ = try work.backend(RecordingBackend.self, identity: clientA) {
                        Issue.record("make must not run on a closed scope")
                        return RecordingBackend()
                    }
                }
                #expect(reason(of: backendError) == endedReason)

                let failError = await captureOperationNotAllow("fail") {
                    try work.fail(TestError.second)
                }
                #expect(reason(of: failError) == endedReason)

                let hookError = await captureOperationNotAllow("onCommitted") {
                    try work.onCommitted { hookRuns.append(1) }
                }
                #expect(reason(of: hookError) == endedReason)

                // The framework path swallows the closed-scope error and rethrows the original.
                await #expect(throws: TestError.second) {
                    try await UnitOfWork.failingCurrentOnError { throw TestError.second }
                }
            })
        }
        // `withUnitOfWork` has returned or thrown; only now does the escaped task go on.
        expectError(error, endingAs: ending)
        let commits = ending == .returns || ending == .commitFails ? 1 : 0
        #expect(backend.commitCount == commits)
        let (closedWork, escaped) = try #require(escapedScope)
        endScope.yield()
        endScope.finish()
        await escaped.value
        let cause: TestError? = ending == .scopeFailed ? .first : nil
        #expect(closedWork.isFailed == (cause != nil))
        #expect(closedWork.failure as? TestError == cause)
        #expect(hookRuns.all.isEmpty)
        #expect(backend.commitCount == commits)
    }

    @Test(
        "An ended scope lets go of its backend and hooks, so a hook that captures the scope does not keep it alive",
        arguments: ScopeEnding.allCases
    )
    func endedScopeReleasesBackendAndHooks(ending: ScopeEnding) async throws {
        weak var weakWork: UnitOfWork?
        weak var weakBackend: RecordingBackend?
        let hookRuns = Recorder<UUID>()
        let error = await runScope(endingAs: ending) { work in
            weakWork = work
            weakBackend = try work.backend(RecordingBackend.self, identity: clientA) {
                makeBackend(endingAs: ending)
            }
            // Captures `work`, as a hook that logs `work.id` would.
            try work.onCommitted { hookRuns.append(work.id) }
        }
        expectError(error, endingAs: ending)
        #expect(hookRuns.all.count == (ending == .returns ? 1 : 0))
        #expect(weakWork == nil, "the ended scope is still alive")
        #expect(weakBackend == nil, "the ended scope's backend is still alive")
    }

    @Test("A body cancelled while it waits throws CancellationError, commits nothing and runs no hook")
    func cancelledBodyCommitsNothing() async throws {
        let backend = RecordingBackend()
        let hookRuns = Recorder<Int>()
        let (parked, park) = AsyncStream.makeStream(of: CheckedContinuation<Void, Never>.self)
        let scope = Task {
            // Ends the wait below even if the body never parks, so a regression fails instead of hanging.
            defer { park.finish() }
            try await withUnitOfWork { work in
                try register(backend, in: work)
                try work.onCommitted { hookRuns.append(1) }
                await withCheckedContinuation { park.yield($0) }
                try Task.checkCancellation()
            }
        }
        for await gate in parked {
            // The body is parked on `gate`: cancel first, then let it continue.
            scope.cancel()
            gate.resume()
            break
        }
        let result = await scope.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(backend.commitCount == 0)
        #expect(hookRuns.all.isEmpty)
    }

    @Test("Each scope has its own id")
    func idsDifferBetweenScopes() async throws {
        let first = try await withUnitOfWork { $0.id }
        let second = try await withUnitOfWork { $0.id }
        #expect(first != second)
    }
}
