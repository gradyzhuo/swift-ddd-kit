import Testing
import Foundation
import KurrentDB
import KurrentSupport
import KurrentSupportInMemory

private struct SampleEvent: Codable, Sendable, Equatable {
    let text: String
}

private func sample(_ text: String) -> EventData {
    EventData(eventType: "SampleEvent", model: SampleEvent(text: text))
}

private func expectResourceDeleted(_ body: () async throws -> Void) async {
    let error = await #expect(throws: KurrentError.self) { try await body() }
    guard case .resourceDeleted = error else {
        Issue.record("expected resourceDeleted, got \(String(describing: error))")
        return
    }
}

@Suite("InMemoryEventStoreClient — tombstone and idempotency")
struct InMemoryEventStoreClientTombstoneTests {

    @Test("after tombstone, read, append, delete and tombstone throw resourceDeleted")
    func tombstoneIsPermanent() async throws {
        let client = InMemoryEventStoreClient()
        _ = try await client.append(events: [sample("a")], toStream: "Order-1", category: "Order", expectedRevision: .noStream)

        try await client.tombstoneStream(name: "Order-1")

        await expectResourceDeleted { _ = try await client.readStream(name: "Order-1", from: .start, resolveLinks: true) }
        await expectResourceDeleted { _ = try await client.append(events: [sample("b")], toStream: "Order-1", category: "Order", expectedRevision: .any) }
        await expectResourceDeleted { try await client.deleteStream(name: "Order-1", expectedRevision: .any) }
        await expectResourceDeleted { try await client.tombstoneStream(name: "Order-1") }
    }

    @Test("tombstoning a stream that never existed succeeds and blocks it")
    func tombstoneUnknownStream() async throws {
        let client = InMemoryEventStoreClient()
        try await client.tombstoneStream(name: "Order-9")
        await expectResourceDeleted { _ = try await client.append(events: [sample("a")], toStream: "Order-9", category: "Order", expectedRevision: .noStream) }
    }

    @Test("resending the same ids with .noStream returns the original revision without writing")
    func idempotentNoStream() async throws {
        let client = InMemoryEventStoreClient()
        let batch = [sample("a"), sample("b")]
        _ = try await client.append(events: batch, toStream: "Order-1", category: "Order", expectedRevision: .noStream)

        let resent = try await client.append(events: batch, toStream: "Order-1", category: "Order", expectedRevision: .noStream)

        #expect(resent == 1)
        let records = try await client.readStream(name: "Order-1", from: .start, resolveLinks: true)
        #expect(records.count == 2)
    }

    @Test("resending the same ids with .at(n) returns the original revision without writing")
    func idempotentAt() async throws {
        let client = InMemoryEventStoreClient()
        _ = try await client.append(events: [sample("a")], toStream: "Order-1", category: "Order", expectedRevision: .noStream)
        let next = [sample("b")]
        _ = try await client.append(events: next, toStream: "Order-1", category: "Order", expectedRevision: .at(0))

        let resent = try await client.append(events: next, toStream: "Order-1", category: "Order", expectedRevision: .at(0))

        #expect(resent == 1)
        let records = try await client.readStream(name: "Order-1", from: .start, resolveLinks: true)
        #expect(records.count == 2)
    }

    @Test("different ids at a stale revision still conflict")
    func differentIdsConflict() async throws {
        let client = InMemoryEventStoreClient()
        _ = try await client.append(events: [sample("a")], toStream: "Order-1", category: "Order", expectedRevision: .noStream)
        await #expect(throws: EventStoreClientError.wrongExpectedRevision(current: 0)) {
            _ = try await client.append(events: [sample("c")], toStream: "Order-1", category: "Order", expectedRevision: .noStream)
        }
    }
}
