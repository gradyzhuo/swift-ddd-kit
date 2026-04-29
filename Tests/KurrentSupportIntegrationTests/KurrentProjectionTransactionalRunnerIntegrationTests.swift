import Testing
import Foundation
import KurrentDB
import KurrentSupport
import PostgresSupport
import EventSourcing
import ReadModelPersistence
import ReadModelPersistencePostgres
import PostgresNIO
import TestUtility
import Logging
import DDDCore

// MARK: - Test fixtures (manually defined — this test target doesn't run the codegen plugin)

private struct DemoEvent: DomainEvent, Codable, Sendable {
    typealias Metadata = Never
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
    var metadata: Never? = nil
    var customerId: String
}

private struct DemoModel: ReadModel, Codable, Sendable {
    typealias ID = String
    let id: String
    var customerId: String = ""
}

private struct DemoInput: CQRSProjectorInput, Sendable { let id: String }

private struct DemoEventMapper: EventTypeMapper {
    func mapping(eventData: RecordedEvent) throws -> (any DomainEvent)? {
        switch eventData.mappingClassName {
        case "DemoEvent":
            return try eventData.decode(to: DemoEvent.self)
        default:
            return nil
        }
    }
}

private struct DemoProjector: EventSourcingProjector, Sendable {
    typealias Input = DemoInput
    typealias ReadModelType = DemoModel
    typealias StorageCoordinator = KurrentStorageCoordinator<DemoProjector>

    static var categoryRule: StreamCategoryRule { .custom("TxDemo") }
    let coordinator: KurrentStorageCoordinator<DemoProjector>
    let throwOnApply: Bool

    func apply(readModel: inout DemoModel, events: [any DomainEvent]) throws {
        if throwOnApply { throw IntentionalApplyFailure() }
        for event in events {
            if let demo = event as? DemoEvent {
                readModel.customerId = demo.customerId
            }
        }
    }

    func buildReadModel(input: DemoInput) throws -> DemoModel? { DemoModel(id: input.id) }
}

private struct IntentionalApplyFailure: Error {}

private func demoAggregateId(from record: RecordedEvent) -> String? {
    let name = record.streamIdentifier.name
    let prefix = "TxDemo-"
    guard name.hasPrefix(prefix) else { return nil }
    return String(name.dropFirst(prefix.count))
}

// MARK: - Suite

@Suite("KurrentProjection.TransactionalSubscriptionRunner — integration", .serialized)
struct KurrentProjectionTransactionalRunnerIntegrationTests {

    private static func makePGClient() -> PostgresClient {
        let cfg = PostgresClient.Configuration(
            host: ProcessInfo.processInfo.environment["PG_HOST"] ?? "localhost",
            port: Int(ProcessInfo.processInfo.environment["PG_PORT"] ?? "5432") ?? 5432,
            username: ProcessInfo.processInfo.environment["PG_USER"] ?? "postgres",
            password: ProcessInfo.processInfo.environment["PG_PASSWORD"] ?? "postgres",
            database: ProcessInfo.processInfo.environment["PG_DATABASE"] ?? "postgres",
            tls: .disable
        )
        return PostgresClient(configuration: cfg)
    }

    @Test("Successful dispatch commits the tx; ReadModel visible after run")
    func happyPath() async throws {
        let kdb = KurrentDBClient.makeIntegrationTestClient()
        let pg = Self.makePGClient()
        let groupName = "tx-runner-happy-\(UUID().uuidString.prefix(8))"
        // Projector's categoryRule is hardcoded `.custom("TxDemo")`, so the
        // subscription must target `$ce-TxDemo` to actually receive the events
        // appended by the coordinator under stream `TxDemo-{aggregateId}`.
        let stream = "$ce-TxDemo"

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await pg.run() }

            try await PostgresReadModelMigration.createTable(on: pg)
            try await kdb.persistentSubscriptions(stream: stream, group: groupName).create { options in
                options.settings.resolveLink = true
            }
            defer { Task { try? await kdb.persistentSubscriptions(stream: stream, group: groupName).delete() } }

            let aggregateId = UUID().uuidString
            let event = DemoEvent(aggregateRootId: aggregateId, customerId: "alice")
            let coordinator = KurrentStorageCoordinator<DemoProjector>(client: kdb, eventMapper: DemoEventMapper())
            _ = try await coordinator.append(events: [event], byId: aggregateId, version: nil, external: nil)

            let projector = DemoProjector(coordinator: coordinator, throwOnApply: false)
            let runner = KurrentProjection.TransactionalSubscriptionRunner(
                client: kdb,
                transactionProvider: PostgresTransactionProvider(client: pg),
                stream: stream,
                groupName: groupName
            )
            .register(
                projector: projector,
                storeFactory: { _ in PostgresTransactionalReadModelStore<DemoModel>() }
            ) { record in
                demoAggregateId(from: record).map(DemoInput.init)
            }

            let task = Task { try await runner.run() }

            // Poll up to 5 seconds for the read model to appear in PG via a non-tx fetch.
            let nonTxStore = PostgresJSONReadModelStore<DemoModel>(client: pg)
            let deadline = Date().addingTimeInterval(5.0)
            var stored: StoredReadModel<DemoModel>? = nil
            while Date() < deadline {
                stored = try await nonTxStore.fetch(byId: aggregateId)
                if stored != nil { break }
                try await Task.sleep(for: .milliseconds(200))
            }

            task.cancel()
            _ = try? await task.value

            #expect(stored?.readModel.customerId == "alice")

            group.cancelAll()
        }
    }

    @Test("Failing projector rolls back tx; no ReadModel committed even on retry")
    func rollbackOnFailure() async throws {
        let kdb = KurrentDBClient.makeIntegrationTestClient()
        let pg = Self.makePGClient()
        let groupName = "tx-runner-rollback-\(UUID().uuidString.prefix(8))"
        // Projector's categoryRule is hardcoded `.custom("TxDemo")`, so the
        // subscription must target `$ce-TxDemo` to actually receive the events
        // appended by the coordinator under stream `TxDemo-{aggregateId}`.
        let stream = "$ce-TxDemo"

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await pg.run() }

            try await PostgresReadModelMigration.createTable(on: pg)
            try await kdb.persistentSubscriptions(stream: stream, group: groupName).create { options in
                options.settings.resolveLink = true
            }
            defer { Task { try? await kdb.persistentSubscriptions(stream: stream, group: groupName).delete() } }

            let aggregateId = UUID().uuidString
            let event = DemoEvent(aggregateRootId: aggregateId, customerId: "bob")
            let coordinator = KurrentStorageCoordinator<DemoProjector>(client: kdb, eventMapper: DemoEventMapper())
            _ = try await coordinator.append(events: [event], byId: aggregateId, version: nil, external: nil)

            // Projector that always throws inside apply — every retry should also fail.
            let projector = DemoProjector(coordinator: coordinator, throwOnApply: true)

            // Tight retry policy so the test exits quickly via .skip after a couple of retries.
            struct QuickSkip: KurrentProjection.RetryPolicy {
                func decide(error: any Error, retryCount: Int) -> KurrentProjection.NackAction {
                    retryCount >= 1 ? .skip : .retry
                }
            }

            let runner = KurrentProjection.TransactionalSubscriptionRunner(
                client: kdb,
                transactionProvider: PostgresTransactionProvider(client: pg),
                stream: stream,
                groupName: groupName,
                retryPolicy: QuickSkip()
            )
            .register(
                projector: projector,
                storeFactory: { _ in PostgresTransactionalReadModelStore<DemoModel>() }
            ) { record in
                demoAggregateId(from: record).map(DemoInput.init)
            }

            let task = Task { try await runner.run() }

            // Wait long enough for at least 2 dispatch attempts to finish (initial + 1 retry → skip).
            try await Task.sleep(for: .seconds(3))
            task.cancel()
            _ = try? await task.value

            // Verify NO read model was committed even though dispatch was triggered.
            let nonTxStore = PostgresJSONReadModelStore<DemoModel>(client: pg)
            let stored = try await nonTxStore.fetch(byId: aggregateId)
            #expect(stored == nil, "Read model should not be committed when projector throws — got \(String(describing: stored?.readModel))")

            group.cancelAll()
        }
    }
}

@Suite("KurrentProjection.TransactionalSubscriptionRunner — convenience init", .serialized)
struct KurrentProjectionTransactionalRunnerConvenienceTests {

    private static func makePGClient() -> PostgresClient {
        let cfg = PostgresClient.Configuration(
            host: ProcessInfo.processInfo.environment["PG_HOST"] ?? "localhost",
            port: Int(ProcessInfo.processInfo.environment["PG_PORT"] ?? "5432") ?? 5432,
            username: ProcessInfo.processInfo.environment["PG_USER"] ?? "postgres",
            password: ProcessInfo.processInfo.environment["PG_PASSWORD"] ?? "postgres",
            database: ProcessInfo.processInfo.environment["PG_DATABASE"] ?? "postgres",
            tls: .disable
        )
        return PostgresClient(configuration: cfg)
    }

    @Test("Convenience init produces a runner using PostgresTransactionProvider")
    func convenienceInitWorks() async throws {
        let kdb = KurrentDBClient.makeIntegrationTestClient()
        let pg = Self.makePGClient()

        let runner = KurrentProjection.TransactionalSubscriptionRunner(
            client: kdb,
            pgClient: pg,
            stream: "$ce-Test",
            groupName: "test-group"
        )
        // Compile-time check — `runner` is a TransactionalSubscriptionRunner<PostgresTransactionProvider>
        let _: KurrentProjection.TransactionalSubscriptionRunner<PostgresTransactionProvider> = runner
    }
}
