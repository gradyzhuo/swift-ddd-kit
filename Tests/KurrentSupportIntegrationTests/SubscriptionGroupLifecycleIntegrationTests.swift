// Tests/KurrentSupportIntegrationTests/SubscriptionGroupLifecycleIntegrationTests.swift
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
import DDDCore

private struct LifecycleEvent: DomainEvent, Codable, Sendable {
    typealias Metadata = Never
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
    var metadata: Never? = nil
    var label: String
}

private struct LifecycleMapper: EventTypeMapper {
    func mapping(eventData: any RecordedEventLike) throws -> (any DomainEvent)? {
        eventData.eventType == "LifecycleEvent" ? try eventData.decode(to: LifecycleEvent.self) : nil
    }
}

private struct LifecycleModel: ReadModel, Codable, Sendable {
    static var readModelTypeName: String { "LifecycleModel.test" }
    let id: String
    var label: String = ""
}

private struct LifecycleInput: CQRSProjectorInput, Sendable { let id: String }

private struct LifecycleProjector: EventSourcingProjector, Sendable {
    typealias Input = LifecycleInput
    typealias ReadModelType = LifecycleModel
    typealias Store = KurrentStorageCoordinator<LifecycleProjector, CustomMetadata>
    static var categoryRule: StreamCategoryRule { .custom("Lifecycle") }
    let store: KurrentStorageCoordinator<LifecycleProjector, CustomMetadata>
    func apply(readModel: inout LifecycleModel, events: [any DomainEvent]) throws {
        for case let e as LifecycleEvent in events { readModel.label = e.label }
    }
    func buildReadModel(input: LifecycleInput) throws -> LifecycleModel? { LifecycleModel(id: input.id) }
}

private func pgClient() -> PostgresClient {
    let env = ProcessInfo.processInfo.environment
    return PostgresClient(configuration: .init(
        host: env["PG_HOST"] ?? "localhost",
        port: Int(env["PG_PORT"] ?? "5432") ?? 5432,
        username: env["PG_USER"] ?? "postgres",
        password: env["PG_PASSWORD"] ?? "postgres",
        database: env["PG_DATABASE"] ?? "postgres",
        tls: .disable
    ))
}

@Suite("Subscription group lifecycle — integration", .serialized)
struct SubscriptionGroupLifecycleIntegrationTests {

    @Test("Live: ensure tolerates an existing group, delete tolerates a missing one, subscribe maps NotFound")
    func liveLifecycle() async throws {
        try await KurrentDBClient.withPooledIntegrationTestClient { kdb in
            let live = LiveEventStoreClient(client: kdb)
            let stream = "$ce-Lifecycle"
            let group = "lifecycle-\(UUID().uuidString.prefix(8))"

            try await live.ensurePersistentSubscription(stream: stream, group: group, settings: .init())
            try await live.ensurePersistentSubscription(stream: stream, group: group, settings: .init())
            try await live.deletePersistentSubscription(stream: stream, group: group)
            try await live.deletePersistentSubscription(stream: stream, group: group)

            await #expect(throws: EventStoreClientError.subscriptionGroupNotFound(stream: stream, group: group)) {
                let session = try await live.subscribePersistent(stream: stream, group: group)
                for try await _ in session.events { break }
            }
        }
    }

    @Test("Live: deleting the group while a session is active ends the session's events stream")
    func deleteWhileSubscribed() async throws {
        try await KurrentDBClient.withPooledIntegrationTestClient { kdb in
            let live = LiveEventStoreClient(client: kdb)
            let stream = "$ce-Lifecycle"
            let group = "lifecycle-mid-\(UUID().uuidString.prefix(8))"

            try await live.ensurePersistentSubscription(stream: stream, group: group, settings: .init())
            let session = try await live.subscribePersistent(stream: stream, group: group)
            try await live.deletePersistentSubscription(stream: stream, group: group)

            // Bounded wait: the stream must end with an error, not hang.
            let outcome: String = try await withThrowingTaskGroup(of: String.self) { tg in
                tg.addTask {
                    do {
                        for try await _ in session.events {}
                        return "finished-without-error"
                    } catch {
                        return "threw: \(type(of: error)) \(error)"
                    }
                }
                tg.addTask {
                    try await Task.sleep(for: .seconds(10))
                    return "timeout"
                }
                let first = try await tg.next()!
                tg.cancelAll()
                return first
            }
            #expect(
                outcome.hasPrefix("threw: EventStoreClientError subscriptionGroupNotFound"),
                "session events must end with subscriptionGroupNotFound, got \(outcome)"
            )
        }
    }

    @Test("End to end: runner fills the monotonic table, rebuild purges and resets, rerun refills it")
    func rebuildEndToEnd() async throws {
        let pg = pgClient()
        try await withThrowingTaskGroup(of: Void.self) { tg in
            tg.addTask { await pg.run() }
            try await KurrentDBClient.withPooledIntegrationTestClient { kdb in
                try await PostgresReadModelMigration.createTable(on: pg)
                let stream = "$ce-Lifecycle"
                let group = "lifecycle-rebuild-\(UUID().uuidString.prefix(8))"
                let id = UUID().uuidString
                let coordinator = KurrentStorageCoordinator<LifecycleProjector, CustomMetadata>(client: kdb, eventMapper: LifecycleMapper())
                _ = try await coordinator.append(events: [LifecycleEvent(aggregateRootId: id, label: "v1")], byId: id, version: nil, metadata: nil)

                func runOnce() async throws -> String? {
                    let runner = KurrentProjection.TransactionalSubscriptionRunner(
                        client: kdb, pgClient: pg, stream: stream, groupName: group
                    )
                    .register(
                        projector: LifecycleProjector(store: coordinator),
                        storeFactory: { _ in PostgresTransactionalReadModelStore<LifecycleModel>() },
                        extractInput: { record in
                            record.streamName.hasPrefix("Lifecycle-")
                                ? LifecycleInput(id: String(record.streamName.dropFirst("Lifecycle-".count))) : nil
                        }
                    )
                    let task = Task { try await runner.run() }
                    defer { task.cancel() }
                    let store = PostgresJSONReadModelStore<LifecycleModel>(client: pg)
                    let deadline = ContinuousClock.now + .seconds(10)
                    while ContinuousClock.now < deadline {
                        if let label = try await store.fetch(byId: id)?.readModel.label { return label }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    return nil
                }

                #expect(try await runOnce() == "v1")

                try await KurrentProjection.rebuild(
                    readModels: [LifecycleModel.self],
                    snapshots: PostgresReadModelSnapshots(client: pg),
                    client: kdb, stream: stream, group: group
                )
                #expect(try await PostgresJSONReadModelStore<LifecycleModel>(client: pg).fetch(byId: id) == nil)

                #expect(try await runOnce() == "v1")
                try await LiveEventStoreClient(client: kdb).deletePersistentSubscription(stream: stream, group: group)
            }
            tg.cancelAll()
        }
    }
}
