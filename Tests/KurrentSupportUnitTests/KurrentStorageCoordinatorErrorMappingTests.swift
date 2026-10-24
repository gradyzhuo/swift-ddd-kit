import Testing
import Foundation
import KurrentDB
import DDDCore
import EventSourcing
import KurrentSupport

// Pins how `KurrentStorageCoordinator` maps the errors a live KurrentDB client
// surfaces (`KurrentError`). `InMemoryEventStoreClient` throws a different shape
// (`EventStoreClientError.wrongExpectedRevision`), so without these tests the
// production `KurrentError` branches would have no offline coverage.

private struct Happened: DomainEvent, Codable, Sendable {
    typealias Metadata = Never
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
    var metadata: Never? = nil
}

private struct NoMapper: EventTypeMapper {
    func mapping(eventData: any RecordedEventLike) throws -> (any DomainEvent)? { nil }
}

private enum Naming: EventStreamNaming {
    static var categoryRule: StreamCategoryRule { .custom("Order") }
    static var category: String { "Order" }
}

/// Throws the configured error from every stream operation.
private struct ThrowingClient: EventStoreClient {
    let error: any Error

    func append(events: [EventData], toStream name: String, category: String, expectedRevision: StreamRevision) async throws -> UInt64? { throw error }
    func readStream(name: String, from revision: RevisionCursor, resolveLinks: Bool) async throws -> [any RecordedEventLike] { throw error }
    func deleteStream(name: String, expectedRevision: StreamRevision) async throws { throw error }
    func tombstoneStream(name: String) async throws { throw error }
    func subscribePersistent(stream: String, group: String) async throws -> any PersistentSubscriptionSession { throw error }
    func ensurePersistentSubscription(stream: String, group: String, settings: PersistentSubscriptionSettings) async throws {}
    func deletePersistentSubscription(stream: String, group: String) async throws {}
}

private func makeCoordinator(throwing error: any Error) -> KurrentStorageCoordinator<Naming, CustomMetadata> {
    .init(client: ThrowingClient(error: error), eventMapper: NoMapper())
}

private func appendOne(
    _ coordinator: KurrentStorageCoordinator<Naming, CustomMetadata>,
    version: UInt64?
) async throws {
    _ = try await coordinator.append(events: [Happened(aggregateRootId: "1")], byId: "1", version: version, metadata: nil)
}

@Suite("KurrentStorageCoordinator maps KurrentError")
struct KurrentStorageCoordinatorErrorMappingTests {
    @Test("wrongExpectedVersion with a current revision becomes commitConflict(expected: nil, actual: 3)")
    func conflictWithRevision() async {
        let error = KurrentError.wrongExpectedVersion(expected: .noStream, current: .revision(3))
        let coordinator = makeCoordinator(throwing: error)
        do {
            try await appendOne(coordinator, version: nil)
            Issue.record("expected a throw")
        } catch let error as DDDError {
            #expect(error.code == .commitConflict)
            #expect(error.commitConflict == .init(id: "1", expected: nil, actual: 3))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("wrongExpectedVersion with no stream becomes commitConflict(expected: 2, actual: nil)")
    func conflictWithNoStream() async {
        let error = KurrentError.wrongExpectedVersion(expected: .revision(2), current: .noStream)
        let coordinator = makeCoordinator(throwing: error)
        do {
            try await appendOne(coordinator, version: 2)
            Issue.record("expected a throw")
        } catch let error as DDDError {
            #expect(error.code == .commitConflict)
            #expect(error.commitConflict == .init(id: "1", expected: 2, actual: nil))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("resourceDeleted on append becomes streamPurged")
    func appendToPurged() async {
        let coordinator = makeCoordinator(throwing: KurrentError.resourceDeleted(resource: "Order-1"))
        do {
            try await appendOne(coordinator, version: nil)
            Issue.record("expected a throw")
        } catch let error as DDDError {
            #expect(error.code == .streamPurged)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("resourceDeleted on fetchEvents (both overloads) returns nil")
    func fetchPurged() async throws {
        let coordinator = makeCoordinator(throwing: KurrentError.resourceDeleted(resource: "Order-1"))
        #expect(try await coordinator.fetchEvents(byId: "1") == nil)
        #expect(try await coordinator.fetchEvents(byId: "1", afterRevision: 4) == nil)
    }

    @Test("purge swallows resourceDeleted")
    func purgeAlreadyPurged() async throws {
        let coordinator = makeCoordinator(throwing: KurrentError.resourceDeleted(resource: "Order-1"))
        try await coordinator.purge(byId: "1")
    }

    @Test("purge rethrows any other error")
    func purgeRethrows() async {
        let coordinator = makeCoordinator(throwing: EventStoreClientError.tombstoneUnsupported)
        await #expect(throws: EventStoreClientError.tombstoneUnsupported) {
            try await coordinator.purge(byId: "1")
        }
    }
}
