import Testing
import Foundation
import EventSourcing
import EventStoreContract
import KurrentDB
import KurrentSupport
import TestUtility

@Suite("Live KurrentDB")
struct LiveKurrentContract {

    @Test("Kurrent coordinator follows the contract")
    func followsContract() async throws {
        try await KurrentDBClient.withPooledIntegrationTestClient { client in
            try await EventStoreContract.checkAll(serialized: true) {
                KurrentStorageCoordinator<ContractStream, ContractMetadata>(
                    client: client,
                    eventMapper: ContractEventMapper()
                )
            }
        }
    }

    @Test("Kurrent coordinator: fetchEvents after a revision at or beyond Int64.max reads an empty window, or nil for a missing stream")
    func fetchAfterHugeRevision() async throws {
        try await KurrentDBClient.withPooledIntegrationTestClient { client in
            let store = KurrentStorageCoordinator<ContractStream, ContractMetadata>(client: client, eventMapper: ContractEventMapper())
            let id = UUID().uuidString
            _ = try await store.append(events: [ContractEvent(aggregateRootId: id, value: 0)], byId: id, version: nil, metadata: nil)
            for revision in [UInt64(Int64.max) - 1, UInt64(Int64.max), UInt64(Int64.max) + 1, .max] {
                let after = try #require(try await store.fetchEvents(byId: id, afterRevision: revision))
                #expect(after.events.isEmpty)
                #expect(after.latestRevision == revision)
                #expect(try await store.fetchEvents(byId: UUID().uuidString, afterRevision: revision) == nil)
            }
        }
    }

    @Test("Kurrent coordinator: huge versions conflict")
    func hugeVersions() async throws {
        try await KurrentDBClient.withPooledIntegrationTestClient { client in
            try await EventStoreContract.checkHugeVersionConflicts {
                KurrentStorageCoordinator<ContractStream, ContractMetadata>(
                    client: client,
                    eventMapper: ContractEventMapper()
                )
            }
        }
    }
}
