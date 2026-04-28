import Testing
import KurrentDB
@testable import KurrentSupport

@Suite("KurrentProjection.PersistentSubscriptionRunner — setup")
struct KurrentProjectionRunnerSetupTests {

    @Test("Can construct runner with default retry policy and logger")
    func constructWithDefaults() {
        let client = KurrentDBClient(settings: .localhost())
        let runner = KurrentProjection.PersistentSubscriptionRunner(
            client: client,
            stream: "$ce-Test",
            groupName: "test-group"
        )
        // Smoke check — runner exists and is Sendable.
        let _: any Sendable = runner
    }

    @Test("Can construct runner with explicit retry policy")
    func constructWithExplicitPolicy() {
        let client = KurrentDBClient(settings: .localhost())
        let runner = KurrentProjection.PersistentSubscriptionRunner(
            client: client,
            stream: "$ce-Test",
            groupName: "test-group",
            retryPolicy: KurrentProjection.MaxRetriesPolicy(max: 3)
        )
        let _: any Sendable = runner
    }

    @Test("register low-level overload is chainable and counts registrations")
    func lowLevelRegisterChains() {
        let client = KurrentDBClient(settings: .localhost())
        let runner = KurrentProjection.PersistentSubscriptionRunner(
            client: client,
            stream: "$ce-Test",
            groupName: "test-group"
        )
        let returned = runner
            .register(extractInput: { _ -> Int? in 1 }, execute: { _ in })
            .register(extractInput: { _ -> String? in nil }, execute: { _ in })

        #expect(returned === runner) // Same instance
        #expect(runner.registrationCount == 2)
    }
}

import EventSourcing
import ReadModelPersistence
import DDDCore
import Foundation

private struct StubReadModel: ReadModel, Sendable {
    typealias ID = String
    let id: String
}

private struct StubInput: CQRSProjectorInput, Sendable {
    let id: String
}

// Minimal in-memory coordinator for tests — never actually called by registration.
private final class StubCoordinator: EventStorageCoordinator, @unchecked Sendable {
    func fetchEvents(byId id: String) async throws -> (events: [any DomainEvent], latestRevision: UInt64)? { nil }
    func fetchEvents(byId id: String, afterRevision revision: UInt64) async throws -> (events: [any DomainEvent], latestRevision: UInt64)? { nil }
    func append(events: [any DomainEvent], byId id: String, version: UInt64?, external: [String : String]?) async throws -> UInt64? { nil }
    func purge(byId id: String) async throws {}
}

private struct StubProjector: EventSourcingProjector {
    typealias Input = StubInput
    typealias ReadModelType = StubReadModel
    typealias StorageCoordinator = StubCoordinator

    let coordinator: StubCoordinator

    func apply(readModel: inout StubReadModel, events: [any DomainEvent]) throws {}
    func buildReadModel(input: StubInput) throws -> StubReadModel? { StubReadModel(id: input.id) }
}

extension KurrentProjectionRunnerSetupTests {

    @Test("register high-level overload (StatefulEventSourcingProjector) is chainable")
    func highLevelRegisterChains() async {
        let client = KurrentDBClient(settings: .localhost())
        let store = await InMemoryReadModelStore<StubReadModel>()
        let projector = StubProjector(coordinator: StubCoordinator())
        let stateful = StatefulEventSourcingProjector(projector: projector, store: store)

        let runner = KurrentProjection.PersistentSubscriptionRunner(
            client: client,
            stream: "$ce-Stub",
            groupName: "stub-group"
        )

        let returned = runner.register(stateful) { _ in StubInput(id: "x") }

        #expect(returned === runner)
        #expect(runner.registrationCount == 1)
    }
}
