import Testing
import EventSourcing
import EventStoreContract

@Suite("EventStore contract")
struct EventStoreContractTests {

    @Test("InMemoryEventStore")
    func inMemoryEventStore() async throws {
        try await EventStoreContract.checkAll(serialized: false) {
            InMemoryEventStore<ContractMetadata>()
        }
    }
}
