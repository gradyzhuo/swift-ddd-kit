import Testing
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
