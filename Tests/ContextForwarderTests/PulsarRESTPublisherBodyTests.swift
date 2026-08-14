import Foundation
import Testing
import PublishedLanguage
@testable import ContextForwarder

@Suite("Pulsar REST produce envelope")
struct PulsarRESTPublisherBodyTests {
    private func envelope(_ event: PublishedLanguageEvent) throws -> [String: Any] {
        let data = try PulsarRESTPublisher.produceBody(for: event)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func message(_ event: PublishedLanguageEvent) throws -> [String: Any] {
        let messages = try envelope(event)["messages"] as! [[String: Any]]
        return messages[0]
    }

    @Test func usesPartitionKeyAsPulsarKey() throws {
        let event = PublishedLanguageEvent(
            eventId: "e-1", eventType: "T.v1",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            recipientIds: ["u-1"], payload: [:], partitionKey: "opportunity-123"
        )
        #expect(try message(event)["key"] as? String == "opportunity-123")
    }

    @Test func fallsBackToEventIdWhenNoPartitionKey() throws {
        let event = PublishedLanguageEvent(
            eventId: "e-1", eventType: "T.v1",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            recipientIds: [], payload: [:]
        )
        #expect(try message(event)["key"] as? String == "e-1")
    }

    @Test func sendsOccurredAtAsMillisecondEventTime() throws {
        let event = PublishedLanguageEvent(
            eventId: "e-1", eventType: "T.v1",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            recipientIds: [], payload: [:]
        )
        #expect(try message(event)["eventTime"] as? Int64 == 1_700_000_000_000)
    }

    /// The payload must stay a raw JSON string, not base64: the REST produce
    /// endpoint encodes server-side. (The WS consume side returns base64 —
    /// that asymmetry is deliberate and is handled in ContextReceiver.)
    @Test func payloadIsRawJSONString() throws {
        let event = PublishedLanguageEvent(
            eventId: "e-1", eventType: "T.v1",
            occurredAt: Date(timeIntervalSince1970: 0),
            recipientIds: [], payload: ["k": "v"]
        )
        let payload = try message(event)["payload"] as! String
        #expect(payload.hasPrefix("{"))
        #expect(payload.contains("\"eventId\":\"e-1\""))
    }
}
