import Foundation
import Testing
import EventSourcing
import EventStoreContract
import KurrentSupport
import KurrentSupportInMemory
import LocalEventStore

@Suite("EventStore contract")
struct EventStoreContractTests {

    @Test("InMemoryEventStore")
    func inMemoryEventStore() async throws {
        try await EventStoreContract.checkAll(serialized: false) {
            InMemoryEventStore<ContractMetadata>()
        }
    }

    @Test("InMemoryEventStore: huge versions conflict instead of trapping")
    func inMemoryEventStoreHugeVersions() async throws {
        try await EventStoreContract.checkHugeVersionConflicts {
            InMemoryEventStore<ContractMetadata>()
        }
    }

    @Test("KurrentStorageCoordinator over InMemoryEventStoreClient")
    func kurrentOverInMemoryClient() async throws {
        try await EventStoreContract.checkAll(serialized: true) {
            KurrentStorageCoordinator<ContractStream, ContractMetadata>(
                client: InMemoryEventStoreClient(),
                eventMapper: ContractEventMapper()
            )
        }
    }

    // Verified against real KurrentDB in `KurrentLiveContractTests`; still
    // outside `checkAll` for now.
    @Test("KurrentStorageCoordinator over InMemoryEventStoreClient: huge versions conflict instead of trapping")
    func kurrentOverInMemoryClientHugeVersions() async throws {
        try await EventStoreContract.checkHugeVersionConflicts {
            KurrentStorageCoordinator<ContractStream, ContractMetadata>(
                client: InMemoryEventStoreClient(),
                eventMapper: ContractEventMapper()
            )
        }
    }

    @Test("PersistentEventStore")
    func persistentEventStore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistentEventStoreContract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await EventStoreContract.checkAll(serialized: true) {
            try PersistentEventStore<ContractStream, ContractMetadata>.open(
                directory: root.appendingPathComponent(UUID().uuidString, isDirectory: true),
                eventMapper: ContractEventMapper()
            )
        }
    }

    @Test("PersistentEventStore: huge versions conflict instead of trapping")
    func persistentEventStoreHugeVersions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistentEventStoreContract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await EventStoreContract.checkHugeVersionConflicts {
            try PersistentEventStore<ContractStream, ContractMetadata>.open(
                directory: root.appendingPathComponent(UUID().uuidString, isDirectory: true),
                eventMapper: ContractEventMapper()
            )
        }
    }
}
