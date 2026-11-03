// Tests/EventSourcingTests/EventSourcingRepositoryUnitOfWorkTests.swift
import DDDCore
import Foundation
import Testing
@testable import EventSourcing

// MARK: - Fixtures

private struct TestMetadata: EventMetadata, Equatable {
    let operatorId: String
}

private struct TicketOpened: DomainEvent {
    typealias Metadata = TestMetadata
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
    var metadata: TestMetadata? = nil
    var title: String
}

private final class Ticket: AggregateRoot {
    struct TicketDeleted: DeletedEvent {
        typealias Metadata = TestMetadata
        var id: UUID = .init()
        var occurred: Date = .now
        var aggregateRootId: String
        var metadata: TestMetadata? = nil

        init(id: UUID, aggregateRootId: String, occurred: Date) {
            self.id = id
            self.aggregateRootId = aggregateRootId
            self.occurred = occurred
        }
    }
    typealias DeletedEventType = TicketDeleted

    let id: String
    private(set) var title: String = ""
    var metadata: AggregateRootMetadata = .init()

    init(id: String, title: String) throws {
        self.id = id
        try apply(event: TicketOpened(aggregateRootId: id, title: title))
    }

    required init?(events: [any DomainEvent]) throws {
        guard let first = events.first as? TicketOpened else { return nil }
        self.id = first.aggregateRootId
        try apply(events: events)
    }

    func when(happened event: some DomainEvent) throws {
        switch event {
        case let e as TicketOpened: title = e.title
        case is TicketDeleted: metadata.delete()
        default: break
        }
    }
}

private struct TicketRepository<Store: EventStore>: EventSourcingRepository {
    typealias AggregateRootType = Ticket

    let store: Store
}

private enum StoreFailure: Error, Equatable {
    case unavailable
}

/// A store that takes part in a unit of work, so the repository's gate lets every call
/// through, and that throws `StoreFailure.unavailable` from each of them.
private struct UnavailableStore: EventStore, UnitOfWorkParticipant {
    typealias Metadata = TestMetadata

    func fetchEvents(byId id: String) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)? {
        throw StoreFailure.unavailable
    }

    func append(
        events: [any DomainEvent],
        byId id: String,
        version: UInt64?,
        metadata: TestMetadata?
    ) async throws -> UInt64? {
        throw StoreFailure.unavailable
    }

    func purge(byId id: String) async throws {
        throw StoreFailure.unavailable
    }
}

private typealias NonParticipantStore = InMemoryEventStore<TestMetadata>

/// The reason the repository gives for refusing `NonParticipantStore` inside a scope.
private let nonParticipantReason = "\(NonParticipantStore.self) cannot take part in a unit of work"

/// The error `body` threw, or nil when it returned.
private func thrownError(_ body: () async throws -> Void) async -> (any Error)? {
    do {
        try await body()
        return nil
    } catch {
        return error
    }
}

private extension DDDError {
    var operation: String? { userInfos["operation"] as? String }
    var reason: String? { userInfos["reason"] as? String }
}

/// Checks that `error` is what `withUnitOfWork` throws for a failed scope: an
/// `operationNotAllow` for "commit" whose cause is `StoreFailure.unavailable`.
private func expectScopeFailedByUnavailableStore(
    _ error: (any Error)?,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let commitError = error as? DDDError
    #expect(commitError?.code == .aggregateOperationNotAllowed, sourceLocation: sourceLocation)
    #expect(commitError?.operation == "commit", sourceLocation: sourceLocation)
    #expect(commitError?.reason == "unit of work failed", sourceLocation: sourceLocation)
    #expect(commitError?.userInfos["cause"] as? StoreFailure == .unavailable, sourceLocation: sourceLocation)
}

// MARK: - Tests

@Suite("EventSourcingRepository inside withUnitOfWork")
struct EventSourcingRepositoryUnitOfWorkTests {

    @Test("save inside a scope throws operationNotAllow for a store that cannot take part, and writes nothing")
    func saveInsideScopeThrowsForNonParticipantStore() async throws {
        let store = NonParticipantStore()
        let repository = TicketRepository(store: store)
        let ticket = try Ticket(id: "t-1", title: "first")

        // The body does not catch the save error, so withUnitOfWork rethrows it.
        let error = await thrownError {
            try await withUnitOfWork { _ in
                try await repository.save(aggregateRoot: ticket)
            }
        }

        let refused = try #require(error as? DDDError)
        #expect(refused.code == .aggregateOperationNotAllowed)
        #expect(refused.operation == "save")
        #expect(refused.reason == nonParticipantReason)
        #expect(refused.reason?.contains("InMemoryEventStore") == true)
        #expect(try await store.fetchEvents(byId: "t-1") == nil)
        #expect(ticket.events.count == 1)
        #expect(ticket.version == nil)
    }

    @Test("save without new events inside a scope still throws for a store that cannot take part")
    func saveWithNoEventsInsideScopeStillThrowsForNonParticipantStore() async throws {
        let repository = TicketRepository(store: NonParticipantStore())
        let ticket = try Ticket(id: "t-1", title: "first")
        try await repository.save(aggregateRoot: ticket)
        #expect(ticket.events.isEmpty)

        let error = await thrownError {
            try await withUnitOfWork { _ in
                try await repository.save(aggregateRoot: ticket)
            }
        }

        let refused = try #require(error as? DDDError)
        #expect(refused.code == .aggregateOperationNotAllowed)
        #expect(refused.operation == "save")
        #expect(refused.reason == nonParticipantReason)
    }

    @Test("purge inside a scope throws operationNotAllow for a store that cannot take part, and purges nothing")
    func purgeInsideScopeThrowsForNonParticipantStore() async throws {
        let store = NonParticipantStore()
        let repository = TicketRepository(store: store)
        try await repository.save(aggregateRoot: try Ticket(id: "t-1", title: "first"))

        let error = await thrownError {
            try await withUnitOfWork { _ in
                try await repository.purge(byId: "t-1")
            }
        }

        let refused = try #require(error as? DDDError)
        #expect(refused.code == .aggregateOperationNotAllowed)
        #expect(refused.operation == "purge")
        #expect(refused.reason == nonParticipantReason)
        #expect(try await store.fetchEvents(byId: "t-1")?.latestRevision == 0)
    }

    @Test("find inside a scope reads from a store that cannot take part, and leaves the scope intact")
    func findInsideScopeWorksForNonParticipantStore() async throws {
        let repository = TicketRepository(store: NonParticipantStore())
        try await repository.save(aggregateRoot: try Ticket(id: "t-1", title: "first"))

        let work = try await withUnitOfWork { work in
            let found = try #require(try await repository.find(byId: "t-1"))
            #expect(found.title == "first")
            #expect(found.version == 0)
            #expect(found.events.isEmpty)
            return work
        }

        #expect(!work.isFailed)
    }

    @Test("save outside a scope writes straight to the store, as before")
    func saveOutsideScopeUnchanged() async throws {
        let store = NonParticipantStore()
        let repository = TicketRepository(store: store)
        let ticket = try Ticket(id: "t-1", title: "first")
        #expect(UnitOfWork.current == nil)

        try await repository.save(aggregateRoot: ticket)

        #expect(ticket.version == 0)
        #expect(ticket.events.isEmpty)
        let stored = try #require(try await store.fetchEvents(byId: "t-1"))
        #expect(stored.latestRevision == 0)
        #expect(stored.events.compactMap { ($0 as? TicketOpened)?.title } == ["first"])
    }

    @Test("A save error caught inside the block still fails the scope, with that error as the cause")
    func errorThrownBySaveInsideScopeFailsTheScope() async throws {
        let repository = TicketRepository(store: NonParticipantStore())
        let ticket = try Ticket(id: "t-1", title: "first")
        var saveError: DDDError?

        let error = await thrownError {
            try await withUnitOfWork { work in
                do {
                    try await repository.save(aggregateRoot: ticket)
                    Issue.record("save must throw inside a scope for a store that cannot take part")
                } catch let refused as DDDError {
                    saveError = refused
                }
                #expect(work.isFailed)
            }
        }

        let commitError = try #require(error as? DDDError)
        #expect(commitError.code == .aggregateOperationNotAllowed)
        #expect(commitError.operation == "commit")
        #expect(commitError.reason == "unit of work failed")
        let cause = try #require(commitError.userInfos["cause"] as? DDDError)
        #expect(cause.operation == "save")
        #expect(cause.reason == nonParticipantReason)
        #expect(saveError?.reason == cause.reason)
    }

    @Test("A purge refusal caught inside the block still fails the scope, with that error as the cause")
    func errorThrownByPurgeInsideScopeFailsTheScope() async throws {
        let store = NonParticipantStore()
        let repository = TicketRepository(store: store)
        try await repository.save(aggregateRoot: try Ticket(id: "t-1", title: "first"))
        var purgeError: DDDError?

        let error = await thrownError {
            try await withUnitOfWork { work in
                do {
                    try await repository.purge(byId: "t-1")
                    Issue.record("purge must throw inside a scope for a store that cannot take part")
                } catch let refused as DDDError {
                    purgeError = refused
                }
                #expect(work.isFailed)
            }
        }

        let commitError = try #require(error as? DDDError)
        #expect(commitError.code == .aggregateOperationNotAllowed)
        #expect(commitError.operation == "commit")
        #expect(commitError.reason == "unit of work failed")
        let cause = try #require(commitError.userInfos["cause"] as? DDDError)
        #expect(cause.code == .aggregateOperationNotAllowed)
        #expect(cause.operation == "purge")
        #expect(cause.reason == nonParticipantReason)
        #expect(purgeError?.operation == cause.operation)
        #expect(purgeError?.reason == cause.reason)
        #expect(try await store.fetchEvents(byId: "t-1")?.latestRevision == 0)
    }

    @Test("A store error from find caught inside the block still fails the scope")
    func errorThrownByFindInsideScopeFailsTheScope() async throws {
        let repository = TicketRepository(store: UnavailableStore())

        let error = await thrownError {
            try await withUnitOfWork { work in
                await #expect(throws: StoreFailure.unavailable) {
                    _ = try await repository.find(byId: "t-1")
                }
                #expect(work.isFailed)
            }
        }

        expectScopeFailedByUnavailableStore(error)
    }

    @Test("A store error from append caught inside the block still fails the scope")
    func errorThrownByStoreAppendInsideScopeFailsTheScope() async throws {
        let repository = TicketRepository(store: UnavailableStore())
        let ticket = try Ticket(id: "t-1", title: "first")

        let error = await thrownError {
            try await withUnitOfWork { work in
                await #expect(throws: StoreFailure.unavailable) {
                    try await repository.save(aggregateRoot: ticket)
                }
                #expect(work.isFailed)
            }
        }

        expectScopeFailedByUnavailableStore(error)
    }

    @Test("A store error from purge caught inside the block still fails the scope")
    func errorThrownByStorePurgeInsideScopeFailsTheScope() async throws {
        let repository = TicketRepository(store: UnavailableStore())

        let error = await thrownError {
            try await withUnitOfWork { work in
                await #expect(throws: StoreFailure.unavailable) {
                    try await repository.purge(byId: "t-1")
                }
                #expect(work.isFailed)
            }
        }

        expectScopeFailedByUnavailableStore(error)
    }

    @Test("delete of a missing aggregate throws aggregateNotFound without failing the scope")
    func deleteOfMissingAggregateDoesNotFailTheScope() async throws {
        let repository = TicketRepository(store: NonParticipantStore())

        let work = try await withUnitOfWork { work in
            do {
                try await repository.delete(byId: "missing")
                Issue.record("delete of a missing aggregate must throw aggregateNotFound")
            } catch let error as DDDError where error.code == .aggregateNotFound {
                // Idempotent delete: the usecase treats a missing aggregate as done.
            }
            return work
        }

        #expect(!work.isFailed)
    }
}
