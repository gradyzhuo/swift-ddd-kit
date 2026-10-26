import Testing
import Foundation
import KurrentDB
import DDDCore
import EventSourcing
import KurrentSupport
import KurrentSupportInMemory

// The huge-version guard in `KurrentStorageCoordinator.append` reads the stream
// to report `actual`; these pin its outcomes for a stream that was never written
// and for a purged one. The existing-stream case is covered by the contract.

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

@Suite("KurrentStorageCoordinator — huge expected version")
struct KurrentStorageCoordinatorHugeVersionTests {

    @Test("on a stream never written it becomes commitConflict(actual: nil)", arguments: [UInt64.max, UInt64(Int64.max) + 1])
    func neverWritten(version: UInt64) async {
        let coordinator = KurrentStorageCoordinator<Naming, CustomMetadata>(client: InMemoryEventStoreClient(), eventMapper: NoMapper())
        do {
            _ = try await coordinator.append(events: [Happened(aggregateRootId: "1")], byId: "1", version: version, metadata: nil)
            Issue.record("expected a throw")
        } catch let error as DDDError {
            #expect(error.code == .commitConflict)
            #expect(error.commitConflict == .init(id: "1", expected: version, actual: nil))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("on a purged stream it becomes streamPurged", arguments: [UInt64.max, UInt64(Int64.max) + 1])
    func purged(version: UInt64) async throws {
        let coordinator = KurrentStorageCoordinator<Naming, CustomMetadata>(client: InMemoryEventStoreClient(), eventMapper: NoMapper())
        _ = try await coordinator.append(events: [Happened(aggregateRootId: "1")], byId: "1", version: nil, metadata: nil)
        try await coordinator.purge(byId: "1")
        do {
            _ = try await coordinator.append(events: [Happened(aggregateRootId: "1")], byId: "1", version: version, metadata: nil)
            Issue.record("expected a throw")
        } catch let error as DDDError {
            #expect(error.code == .streamPurged)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
