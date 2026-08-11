import Foundation
import Testing
@testable import ContextForwarder

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
}
