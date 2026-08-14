import Foundation
import Testing
@testable import PublishedLanguage

@Suite("PublishedLanguageEvent wire format")
struct PublishedLanguageEventTests {

    @Test("encodes deterministically with iso8601 dates and sorted keys")
    func stableEncoding() throws {
        let event = PublishedLanguageEvent(
            eventId: "evt-1",
            eventType: "OpportunityCollaboratorAdded.v1",
            occurredAt: Date(timeIntervalSince1970: 1_000_000),
            recipientIds: ["acc-1"],
            payload: ["caseName": "台積電查核", "role": "editor"]
        )

        let json = try PublishedLanguageEvent.wireEncoder.encode(event)
        let string = try #require(String(data: json, encoding: .utf8))

        #expect(string.contains("\"eventType\":\"OpportunityCollaboratorAdded.v1\""))
        #expect(string.contains("1970-01-12T13:46:40Z"))
        // Deterministic: encoding twice yields identical bytes.
        #expect(try PublishedLanguageEvent.wireEncoder.encode(event) == json)
        // Roundtrip.
        #expect(try PublishedLanguageEvent.wireDecoder.decode(PublishedLanguageEvent.self, from: json) == event)
    }

    /// An event written by the pre-partitionKey forwarder must still decode.
    @Test func decodesLegacyPayloadWithoutPartitionKey() throws {
        let legacy = """
        {"eventId":"e-1","eventType":"OpportunityCollaboratorAdded.v1",\
        "occurredAt":"2026-08-14T01:02:03Z","recipientIds":["u-1"],\
        "payload":{"opportunityId":"o-1"}}
        """
        let event = try PublishedLanguageEvent.wireDecoder.decode(
            PublishedLanguageEvent.self, from: Data(legacy.utf8)
        )
        #expect(event.eventId == "e-1")
        #expect(event.partitionKey == nil)
        #expect(event.effectivePartitionKey == "e-1")
    }

    @Test func effectivePartitionKeyPrefersExplicitKey() {
        let event = PublishedLanguageEvent(
            eventId: "e-1",
            eventType: "T.v1",
            occurredAt: Date(timeIntervalSince1970: 0),
            recipientIds: ["u-1"],
            payload: [:],
            partitionKey: "opportunity-123"
        )
        #expect(event.effectivePartitionKey == "opportunity-123")
    }

    /// Absent partitionKey must not appear in the encoded bytes at all,
    /// so existing consumers see a byte-identical wire format.
    @Test func omitsNilPartitionKeyFromEncodedForm() throws {
        let event = PublishedLanguageEvent(
            eventId: "e-1", eventType: "T.v1",
            occurredAt: Date(timeIntervalSince1970: 0),
            recipientIds: [], payload: [:]
        )
        let json = try PublishedLanguageEvent.wireEncoder.encode(event)
        #expect(!String(decoding: json, as: UTF8.self).contains("partitionKey"))
    }
}
