import Testing
import EventSourcing
import EventStoreContract
import KurrentSupport
import KurrentSupportInMemory

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

    // Real KurrentDB behaviour for huge revisions is unverified until the live
    // contract run, so this stays outside `checkAll` for now.
    @Test("KurrentStorageCoordinator over InMemoryEventStoreClient: huge versions conflict instead of trapping")
    func kurrentOverInMemoryClientHugeVersions() async throws {
        try await EventStoreContract.checkHugeVersionConflicts {
            KurrentStorageCoordinator<ContractStream, ContractMetadata>(
                client: InMemoryEventStoreClient(),
                eventMapper: ContractEventMapper()
            )
        }
    }
}
