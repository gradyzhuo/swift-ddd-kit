import Foundation
import Testing
import DDDCore
import EventStoreContract
@testable import LocalEventStore

private typealias Store = PersistentEventStore<ContractStream, ContractMetadata>

private func open(_ directory: URL) throws -> Store {
    try Store.open(directory: directory, eventMapper: ContractEventMapper())
}

private func fileURL(_ directory: URL, id: String) throws -> URL {
    directory.appendingPathComponent(try StreamFile.fileName(forStream: ContractStream.getStreamName(id: id)))
}

enum Corruption: String, CaseIterable, Sendable {
    case truncated, empty, futureFormat, wrongStream
}

@Suite("PersistentEventStore on disk")
struct PersistentEventStoreFileTests {

    @Test("events, revisions and metadata survive close and reopen")
    func eventsSurviveReopen() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID().uuidString
        let events = [ContractEvent(aggregateRootId: id, value: 1), ContractEvent(aggregateRootId: id, value: 2)]

        let first = try open(directory)
        let revision = try await first.append(events: events, byId: id, version: nil, metadata: ContractMetadata(tag: "m"))
        #expect(revision == 1)
        await first.close()

        let second = try open(directory)
        let fetched = try #require(try await second.fetchEvents(byId: id))
        #expect(fetched.latestRevision == 1)
        let read = fetched.events.compactMap { $0 as? ContractEvent }
        #expect(read.map(\.id) == events.map { $0.id })
        #expect(read.map(\.value) == [1, 2])
        #expect(read.map(\.metadata?.tag) == ["m", "m"])
        #expect(try await second.append(events: [ContractEvent(aggregateRootId: id, value: 3)], byId: id, version: 1, metadata: nil) == 2)
        await second.close()
    }

    @Test("purge survives reopen and removes the payload from the stream file")
    func purgeSurvivesReopenAndDropsPayload() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID().uuidString
        let event = ContractEvent(aggregateRootId: id, value: 7)
        let file = try fileURL(directory, id: id)

        let first = try open(directory)
        _ = try await first.append(events: [event], byId: id, version: nil, metadata: ContractMetadata(tag: "secret"))
        let before = try JSONDecoder().decode(StreamFile.self, from: Data(contentsOf: file))
        let payload = try #require(before.records.first?.payload.base64EncodedString())
        #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(payload))
        try await first.purge(byId: id)
        await first.close()

        let second = try open(directory)
        #expect(try await second.fetchEvents(byId: id) == nil)
        #expect(try await second.fetchEvents(byId: id, afterRevision: 0) == nil)
        #expect(await dddError {
            _ = try await second.append(events: [ContractEvent(aggregateRootId: id, value: 8)], byId: id, version: nil, metadata: nil)
        }?.code == .streamPurged)

        let bytes = try Data(contentsOf: file)
        let after = try JSONDecoder().decode(StreamFile.self, from: bytes)
        #expect(after.purged)
        #expect(after.records.isEmpty)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains(payload))
        #expect(!text.contains(event.id.uuidString))
        await second.close()
    }

    @Test("a corrupted stream file fails reads and appends without being rewritten", arguments: Corruption.allCases)
    func corruptedStream(_ corruption: Corruption) async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try open(directory)
        let broken = UUID().uuidString
        let healthy = UUID().uuidString
        _ = try await store.append(events: [ContractEvent(aggregateRootId: broken, value: 1)], byId: broken, version: nil, metadata: nil)
        let healthyEvent = ContractEvent(aggregateRootId: healthy, value: 2)
        _ = try await store.append(events: [healthyEvent], byId: healthy, version: nil, metadata: nil)

        let brokenFile = try fileURL(directory, id: broken)
        let original = try Data(contentsOf: brokenFile)
        let corrupted: Data
        switch corruption {
        case .truncated:
            corrupted = original.prefix(original.count / 2)
        case .empty:
            corrupted = Data()
        case .futureFormat:
            var json = try #require(try JSONSerialization.jsonObject(with: original) as? [String: Any])
            json["formatVersion"] = 2
            corrupted = try JSONSerialization.data(withJSONObject: json)
        case .wrongStream:
            corrupted = try Data(contentsOf: fileURL(directory, id: healthy))
        }
        try corrupted.write(to: brokenFile)
        let brokenStream = ContractStream.getStreamName(id: broken)

        #expect(await dddError { _ = try await store.fetchEvents(byId: broken) }?.corruptedStream == brokenStream)
        #expect(await dddError { _ = try await store.fetchEvents(byId: broken, afterRevision: 0) }?.corruptedStream == brokenStream)
        for version: UInt64? in [nil, 0] {
            #expect(await dddError {
                _ = try await store.append(events: [ContractEvent(aggregateRootId: broken, value: 3)], byId: broken, version: version, metadata: nil)
            }?.corruptedStream == brokenStream)
        }
        #expect(try Data(contentsOf: brokenFile) == corrupted)
        #expect(try await store.fetchEvents(byId: healthy)?.events.map { $0.id } == [healthyEvent.id])

        try await store.purge(byId: broken)
        #expect(try await store.fetchEvents(byId: broken) == nil)
        #expect(try await store.fetchEvents(byId: healthy)?.events.map { $0.id } == [healthyEvent.id])
        await store.close()
    }

    @Test("only a missing file means the stream does not exist: any other read failure is an I/O error")
    func unreadableStreamFileIsAnIOError() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try open(directory)
        let blocked = UUID().uuidString
        let healthy = UUID().uuidString
        let healthyEvent = ContractEvent(aggregateRootId: healthy, value: 1)
        _ = try await store.append(events: [healthyEvent], byId: healthy, version: nil, metadata: nil)

        // A directory where the stream file belongs: reading it fails, but not with "no such file".
        let blockedPath = try fileURL(directory, id: blocked)
        try FileManager.default.createDirectory(at: blockedPath, withIntermediateDirectories: false)

        let event = ContractEvent(aggregateRootId: blocked, value: 2)
        #expect(await dddError { _ = try await store.fetchEvents(byId: blocked) }?.storeUnavailableReason == .io)
        #expect(await dddError { _ = try await store.fetchEvents(byId: blocked, afterRevision: 0) }?.storeUnavailableReason == .io)
        #expect(await dddError { _ = try await store.append(events: [event], byId: blocked, version: nil, metadata: nil) }?
            .storeUnavailableReason == .io)
        #expect(await dddError { try await store.purge(byId: blocked) }?.storeUnavailableReason == .io)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: blockedPath.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(try await store.fetchEvents(byId: healthy)?.events.map { $0.id } == [healthyEvent.id])
        await store.close()
    }

    @Test("stream names that differ only in case use separate files")
    func caseSensitiveStreamNames() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try open(directory)
        let lower = "case-\(UUID().uuidString.lowercased())"
        let upper = lower.uppercased()
        let lowerEvent = ContractEvent(aggregateRootId: lower, value: 1)
        let upperEvent = ContractEvent(aggregateRootId: upper, value: 2)

        _ = try await store.append(events: [lowerEvent], byId: lower, version: nil, metadata: nil)
        _ = try await store.append(events: [upperEvent], byId: upper, version: nil, metadata: nil)

        #expect(try await store.fetchEvents(byId: lower)?.events.map { $0.id } == [lowerEvent.id])
        #expect(try await store.fetchEvents(byId: upper)?.events.map { $0.id } == [upperEvent.id])
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        #expect(names.contains(try StreamFile.fileName(forStream: ContractStream.getStreamName(id: lower))))
        #expect(names.contains(try StreamFile.fileName(forStream: ContractStream.getStreamName(id: upper))))
        await store.close()
    }

    @Test("a stream name over 120 UTF-8 bytes is rejected by every operation")
    func streamNameTooLong() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try open(directory)
        let prefixBytes = ContractStream.getStreamName(id: "").utf8.count
        let longest = String(repeating: "x", count: 120 - prefixBytes)
        let tooLong = longest + "x"

        #expect(try await store.append(events: [ContractEvent(aggregateRootId: longest, value: 1)], byId: longest, version: nil, metadata: nil) == 0)

        let event = ContractEvent(aggregateRootId: tooLong, value: 1)
        #expect(await dddError { _ = try await store.append(events: [event], byId: tooLong, version: nil, metadata: nil) }?
            .storeUnavailableReason == .streamNameTooLong)
        #expect(await dddError { _ = try await store.fetchEvents(byId: tooLong) }?.storeUnavailableReason == .streamNameTooLong)
        #expect(await dddError { _ = try await store.fetchEvents(byId: tooLong, afterRevision: 0) }?
            .storeUnavailableReason == .streamNameTooLong)
        #expect(await dddError { try await store.purge(byId: tooLong) }?.storeUnavailableReason == .streamNameTooLong)
        await store.close()
    }

    @Test("a closed store rejects every operation except an empty append")
    func closedStoreRejectsOperations() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try open(directory)
        let id = UUID().uuidString
        await store.close()

        #expect(try await store.append(events: [], byId: id, version: nil, metadata: nil) == nil)
        let event = ContractEvent(aggregateRootId: id, value: 1)
        #expect(await dddError { _ = try await store.append(events: [event], byId: id, version: nil, metadata: nil) }?
            .storeUnavailableReason == .closed)
        #expect(await dddError { _ = try await store.fetchEvents(byId: id) }?.storeUnavailableReason == .closed)
        #expect(await dddError { _ = try await store.fetchEvents(byId: id, afterRevision: 0) }?.storeUnavailableReason == .closed)
        #expect(await dddError { try await store.purge(byId: id) }?.storeUnavailableReason == .closed)
    }
}
