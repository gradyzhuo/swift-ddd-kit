import Testing
import Foundation
import Synchronization
import KurrentDB
import DDDCore
import EventSourcing
import ReadModelPersistence
import KurrentSupport
import KurrentSupportInMemory

private struct Placed: DomainEvent, Codable, Sendable {
    typealias Metadata = Never
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
    var metadata: Never? = nil
}

private struct PlacedMapper: EventTypeMapper {
    func mapping(eventData: any RecordedEventLike) throws -> (any DomainEvent)? {
        eventData.eventType == "Placed" ? try eventData.decode(to: Placed.self) : nil
    }
}

private struct SeqModel: ReadModel, Codable, Sendable { let id: String }
private struct SeqInput: CQRSProjectorInput, Sendable { let id: String }

private struct SeqProjector: EventSourcingProjector, Sendable {
    typealias Input = SeqInput
    typealias ReadModelType = SeqModel
    typealias Store = KurrentStorageCoordinator<SeqProjector, CustomMetadata>
    static var categoryRule: StreamCategoryRule { .custom("Seq") }
    let store: KurrentStorageCoordinator<SeqProjector, CustomMetadata>
    func apply(readModel: inout SeqModel, events: [any DomainEvent]) throws {}
    func buildReadModel(input: SeqInput) throws -> SeqModel? { SeqModel(id: input.id) }
}

private final class Log: Sendable { let entries = Mutex<[String]>([]) }

/// Records fetch/save calls; label "A" sleeps in fetch so a parallel dispatch would interleave.
private struct RecordingStore: TransactionalReadModelStore {
    typealias Model = SeqModel
    typealias Transaction = Int
    let label: String
    let log: Log
    let failOnSave: Bool

    func fetch(byId id: String, in transaction: Int) async throws -> StoredReadModel<SeqModel>? {
        log.entries.withLock { $0.append("\(label).fetch") }
        if label == "A" { try await Task.sleep(for: .milliseconds(50)) }
        return nil
    }
    func save(readModel: SeqModel, revision: UInt64, in transaction: Int) async throws {
        log.entries.withLock { $0.append("\(label).save") }
        if failOnSave { struct Boom: Error {}; throw Boom() }
    }
}

@Suite("TransactionalSubscriptionRunner — sequential dispatch")
struct TransactionalSequentialDispatchTests {

    private func run(failA: Bool) async throws -> [String] {
        let client = InMemoryEventStoreClient()
        let coordinator = KurrentStorageCoordinator<SeqProjector, CustomMetadata>(client: client, eventMapper: PlacedMapper())
        _ = try await coordinator.append(events: [Placed(aggregateRootId: "1")], byId: "1", version: nil, metadata: nil)

        let log = Log()
        let projector = SeqProjector(store: coordinator)
        let extract: @Sendable (any RecordedEventLike) -> SeqInput? = { _ in SeqInput(id: "1") }
        let runner = KurrentProjection.TransactionalSubscriptionRunner(
            client: client, transactionProvider: NoopProvider(), stream: "$ce-Seq", groupName: "g",
            retryPolicy: KurrentProjection.MaxRetriesPolicy(max: 0)
        )
        .register(projector: projector, storeFactory: { _ in RecordingStore(label: "A", log: log, failOnSave: failA) }, extractInput: extract)
        .register(projector: projector, storeFactory: { _ in RecordingStore(label: "B", log: log, failOnSave: false) }, extractInput: extract)

        let task = Task { try await runner.run() }
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline, log.entries.withLock({ $0.count }) < (failA ? 2 : 4) {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(100)) // let any (wrong) parallel sibling show up
        task.cancel()
        return log.entries.withLock { $0 }
    }

    @Test("Projectors run one after another in registration order")
    func registrationOrder() async throws {
        #expect(try await run(failA: false) == ["A.fetch", "A.save", "B.fetch", "B.save"])
    }

    @Test("A failing projector stops the ones registered after it")
    func stopsAfterFailure() async throws {
        #expect(try await run(failA: true) == ["A.fetch", "A.save"])
    }
}
