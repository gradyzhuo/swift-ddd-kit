// Tests/LocalEventStoreTests/PersistentEventStoreUnitOfWorkTests.swift
import DDDCore
import EventSourcing
import Foundation
import Testing
@testable import LocalEventStore

// MARK: - Fixtures

private struct TestMetadata: EventMetadata, Equatable {
    let operatorId: String
}

private struct NoteWritten: DomainEvent {
    typealias Metadata = TestMetadata
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
    var metadata: TestMetadata? = nil
    var text: String
}

private final class Note: AggregateRoot {
    struct NoteDeleted: DeletedEvent {
        typealias Metadata = TestMetadata
        var id: UUID = .init()
        var occurred: Date = .now
        var aggregateRootId: String
        var metadata: TestMetadata? = nil

        init(id: UUID, aggregateRootId: String, occurred: Date) {
            self.id = id
            self.aggregateRootId = aggregateRootId
            self.occurred = occurred
        }
    }
    typealias DeletedEventType = NoteDeleted

    let id: String
    private(set) var text: String = ""
    var metadata: AggregateRootMetadata = .init()

    init(id: String, text: String) throws {
        self.id = id
        try write(text)
    }

    required init?(events: [any DomainEvent]) throws {
        guard let first = events.first as? NoteWritten else { return nil }
        self.id = first.aggregateRootId
        try apply(events: events)
    }

    func write(_ text: String) throws {
        try apply(event: NoteWritten(aggregateRootId: id, text: text))
    }

    func when(happened event: some DomainEvent) throws {
        switch event {
        case let e as NoteWritten: text = e.text
        case is NoteDeleted: metadata.delete()
        default: break
        }
    }
}

private struct NoteMapper: EventTypeMapper {
    func mapping(eventData: any RecordedEventLike) throws -> (any DomainEvent)? {
        switch eventData.eventType {
        case "NoteWritten": return try eventData.decode(to: NoteWritten.self)
        default: return nil
        }
    }
}

private typealias NoteStore = PersistentEventStore<Note, TestMetadata>

private struct NoteRepository: EventSourcingRepository {
    typealias AggregateRootType = Note

    let store: NoteStore
}

private func streamFile(in directory: URL, id: String) throws -> URL {
    directory.appendingPathComponent(try StreamFile.fileName(forStream: Note.getStreamName(id: id)))
}

// MARK: - Tests

@Suite("PersistentEventStore inside withUnitOfWork")
struct PersistentEventStoreUnitOfWorkTests {

    @Test("save inside a scope throws operationNotAllow and leaves the stream file unchanged")
    func saveInsideScopeThrowsForPersistentEventStore() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NoteStore.open(directory: directory, eventMapper: NoteMapper())
        let repository = NoteRepository(store: store)
        let note = try Note(id: "n-1", text: "first")
        try await repository.save(aggregateRoot: note)
        let file = try streamFile(in: directory, id: "n-1")
        let before = try Data(contentsOf: file)

        try note.write("second")
        let error = await dddError {
            try await withUnitOfWork { _ in
                try await repository.save(aggregateRoot: note)
            }
        }

        #expect(error?.code == .aggregateOperationNotAllowed)
        #expect(error?.userInfos["operation"] as? String == "save")
        #expect(error?.userInfos["reason"] as? String == "\(NoteStore.self) cannot take part in a unit of work")
        #expect(try Data(contentsOf: file) == before)
        #expect(note.version == 0)
        #expect(note.events.count == 1)
        await store.close()
    }

    @Test("find inside a scope reads the stream and leaves the scope intact")
    func findInsideScopeWorksForPersistentEventStore() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NoteStore.open(directory: directory, eventMapper: NoteMapper())
        let repository = NoteRepository(store: store)
        let note = try Note(id: "n-1", text: "first")
        try note.write("second")
        try await repository.save(aggregateRoot: note)

        let work = try await withUnitOfWork { work in
            let found = try #require(try await repository.find(byId: "n-1"))
            #expect(found.text == "second")
            #expect(found.version == 1)
            #expect(found.events.isEmpty)
            return work
        }

        #expect(!work.isFailed)
        await store.close()
    }
}
