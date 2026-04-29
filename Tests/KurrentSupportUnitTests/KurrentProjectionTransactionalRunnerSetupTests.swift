import Testing
import KurrentDB
import EventSourcing
import ReadModelPersistence
import DDDCore
import Foundation
@testable import KurrentSupport

@Suite("KurrentProjection.TransactionalSubscriptionRunner — setup")
struct KurrentProjectionTransactionalRunnerSetupTests {

    /// Stub provider for unit testing — no real backend.
    struct StubProvider: TransactionProvider {
        struct StubTx: Sendable {}
        func withTransaction<Result: Sendable>(_ body: (StubTx) async throws -> Result) async throws -> Result {
            try await body(StubTx())
        }
    }

    @Test("Can construct runner with a provider and default retry policy")
    func constructWithDefaults() {
        let client = KurrentDBClient(settings: .localhost())
        let runner = KurrentProjection.TransactionalSubscriptionRunner(
            client: client,
            transactionProvider: StubProvider(),
            stream: "$ce-Test",
            groupName: "test-group"
        )
        let _: any Sendable = runner
    }

    @Test("Can construct runner with explicit retry policy")
    func constructWithExplicitPolicy() {
        let client = KurrentDBClient(settings: .localhost())
        let runner = KurrentProjection.TransactionalSubscriptionRunner(
            client: client,
            transactionProvider: StubProvider(),
            stream: "$ce-Test",
            groupName: "test-group",
            retryPolicy: KurrentProjection.MaxRetriesPolicy(max: 3)
        )
        let _: any Sendable = runner
    }

    @Test("register chains and counts registrations")
    func registerChains() async {
        let client = KurrentDBClient(settings: .localhost())
        let runner = KurrentProjection.TransactionalSubscriptionRunner(
            client: client,
            transactionProvider: StubProvider(),
            stream: "$ce-Test",
            groupName: "test-group"
        )

        let projector = StubProjector(coordinator: StubCoordinator())

        let returned = runner
            .register(
                projector: projector,
                storeFactory: { _ in StubTransactionalStore() }
            ) { _ in StubInput(id: "x") }
            .register(
                projector: projector,
                storeFactory: { _ in StubTransactionalStore() }
            ) { _ in nil }

        #expect(returned === runner)
        #expect(runner._registrationCountForTesting == 2)
    }

    @Test("_shouldDispatchTx with nil filter returns true")
    func nilFilterPassesThrough() {
        #expect(KurrentProjection.TransactionalSubscriptionRunner<StubProvider>._shouldDispatchTx(
            eventType: "Anything", filter: nil) == true)
    }

    @Test("_shouldDispatchTx with filter checks handles()")
    func filterIsRespected() {
        struct OnlyA: EventTypeFilter {
            func handles(eventType: String) -> Bool { eventType == "A" }
        }
        let f = OnlyA()
        #expect(KurrentProjection.TransactionalSubscriptionRunner<StubProvider>._shouldDispatchTx(
            eventType: "A", filter: f) == true)
        #expect(KurrentProjection.TransactionalSubscriptionRunner<StubProvider>._shouldDispatchTx(
            eventType: "B", filter: f) == false)
    }
}

// MARK: - Fixtures

private struct StubReadModel: ReadModel, Sendable {
    typealias ID = String
    let id: String
}

private struct StubInput: CQRSProjectorInput, Sendable { let id: String }

private struct StubCoordinator: EventStorageCoordinator {
    func fetchEvents(byId id: String) async throws -> (events: [any DomainEvent], latestRevision: UInt64)? { nil }
    func fetchEvents(byId id: String, afterRevision revision: UInt64) async throws -> (events: [any DomainEvent], latestRevision: UInt64)? { nil }
    func append(events: [any DomainEvent], byId id: String, version: UInt64?, external: [String : String]?) async throws -> UInt64? { nil }
    func purge(byId id: String) async throws {}
}

private struct StubProjector: EventSourcingProjector, Sendable {
    typealias Input = StubInput
    typealias ReadModelType = StubReadModel
    typealias StorageCoordinator = StubCoordinator

    let coordinator: StubCoordinator

    func apply(readModel: inout StubReadModel, events: [any DomainEvent]) throws {}
    func buildReadModel(input: StubInput) throws -> StubReadModel? { StubReadModel(id: input.id) }
}

private struct StubTransactionalStore: TransactionalReadModelStore {
    typealias Model = StubReadModel
    typealias Transaction = KurrentProjectionTransactionalRunnerSetupTests.StubProvider.StubTx
    func save(readModel: StubReadModel, revision: UInt64, in transaction: Transaction) async throws {}
    func fetch(byId id: String, in transaction: Transaction) async throws -> StoredReadModel<StubReadModel>? { nil }
}
