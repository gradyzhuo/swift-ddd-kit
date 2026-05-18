// Tests/KurrentSupportIntegrationTests/KurrentMetadataRoundtripTests.swift
import Foundation
import Testing
import DDDCore
import EventSourcing
import KurrentDB
@testable import KurrentSupport

// MARK: - Fixtures

private struct RoundtripEvent: DomainEvent {
    typealias Metadata = CustomMetadata
    var id: UUID = .init()
    var occurred: Date = .now
    var aggregateRootId: String
    var metadata: CustomMetadata? = nil
    var note: String
}

private struct RoundtripEventMapper: EventTypeMapper {
    init() {}
    func mapping(eventData: RecordedEvent) throws -> (any DomainEvent)? {
        guard eventData.mappingClassName == "RoundtripEvent" else { return nil }
        guard var event = try eventData.decode(to: RoundtripEvent.self) else { return nil }
        if !eventData.customMetadata.isEmpty {
            let decoder = JSONDecoder()
            event.metadata = try? decoder.decode(CustomMetadata.self, from: eventData.customMetadata)
        }
        return event
    }
}

private enum RoundtripStream: EventStreamNaming {
    static var categoryRule: StreamCategoryRule { .custom("RoundtripDemo") }
    static var category: String { "RoundtripDemo" }
}

// MARK: - Suite

@Suite("Kurrent metadata round-trip", .serialized)
struct KurrentMetadataRoundtripTests {

    @Test("metadata written via ambient context is recoverable via event.metadata on read")
    func ambientToCustomMetadataRoundtrip() async throws {
        let kdb = KurrentDBClient.makeIntegrationTestClient()
        let store = KurrentStorageCoordinator<RoundtripStream, CustomMetadata>(
            client: kdb,
            eventMapper: RoundtripEventMapper()
        )

        let aggregateId = UUID().uuidString
        let written = CustomMetadata(
            className: "RoundtripEvent",
            external: ["operatorId": "alice", "tenantId": "t-1"]
        )
        let event = RoundtripEvent(aggregateRootId: aggregateId, note: "hello")

        // Write side — ambient + direct store.append
        try await EventMetadataContext<CustomMetadata>.withValue(written) {
            let metadata = EventMetadataContext<CustomMetadata>.current
            _ = try await store.append(
                events: [event],
                byId: aggregateId,
                version: nil,
                metadata: metadata
            )
        }

        // Read side — mapper populates event.metadata
        guard let result = try await store.fetchEvents(byId: aggregateId) else {
            Issue.record("fetchEvents returned nil for aggregate \(aggregateId)")
            return
        }
        guard let readEvent = result.events.first as? RoundtripEvent else {
            Issue.record("First event is not RoundtripEvent")
            return
        }
        #expect(readEvent.metadata?.external?["operatorId"] == "alice")
        #expect(readEvent.metadata?.external?["tenantId"] == "t-1")
        #expect(readEvent.note == "hello")
    }

    @Test("no ambient context yields nil event.metadata on read")
    func noAmbientYieldsNilMetadata() async throws {
        let kdb = KurrentDBClient.makeIntegrationTestClient()
        let store = KurrentStorageCoordinator<RoundtripStream, CustomMetadata>(
            client: kdb,
            eventMapper: RoundtripEventMapper()
        )

        let aggregateId = UUID().uuidString
        let event = RoundtripEvent(aggregateRootId: aggregateId, note: "no meta")

        // No EventMetadataContext.withValue — metadata is nil
        _ = try await store.append(
            events: [event],
            byId: aggregateId,
            version: nil,
            metadata: nil
        )

        guard let result = try await store.fetchEvents(byId: aggregateId) else {
            Issue.record("fetchEvents returned nil")
            return
        }
        guard let readEvent = result.events.first as? RoundtripEvent else {
            Issue.record("First event is not RoundtripEvent")
            return
        }
        #expect(readEvent.metadata == nil)
    }
}
