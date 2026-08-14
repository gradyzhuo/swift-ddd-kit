import Foundation
import Testing
import PublishedLanguage
@testable import ContextReceiver

@Suite("Consumer frame decoding")
struct ConsumerFrameTests {
    private func frameJSON(payload: String, redeliveryCount: String = "0") -> Data {
        Data("""
        {"messageId":"CAAQAw==","payload":"\(payload)",\
        "publishTime":"2026-08-14T01:02:03.000Z","redeliveryCount":\(redeliveryCount),\
        "properties":{"eventType":"T.v1"},"key":"opportunity-123"}
        """.utf8)
    }

    private var eventPayloadBase64: String {
        let json = """
        {"eventId":"e-1","eventType":"T.v1","occurredAt":"2026-08-14T01:02:03Z",\
        "recipientIds":["u-1"],"payload":{"opportunityId":"o-1"}}
        """
        return Data(json.utf8).base64EncodedString()
    }

    @Test func decodesFrameFields() throws {
        let frame = try ConsumerFrame(json: frameJSON(payload: eventPayloadBase64))
        #expect(frame.messageId == "CAAQAw==")
        #expect(frame.redeliveryCount == 0)
        #expect(frame.key == "opportunity-123")
        #expect(frame.properties["eventType"] == "T.v1")
    }

    /// The consume side delivers payload base64-encoded even though the REST
    /// produce side takes a raw string. This is the asymmetry that would
    /// otherwise fail silently end-to-end.
    @Test func base64DecodesPayloadIntoEvent() throws {
        let frame = try ConsumerFrame(json: frameJSON(payload: eventPayloadBase64))
        let event = try frame.decodedEvent()
        #expect(event.eventId == "e-1")
        #expect(event.recipientIds == ["u-1"])
        #expect(event.payload["opportunityId"] == "o-1")
    }

    @Test func rejectsNonBase64Payload() throws {
        let frame = try ConsumerFrame(json: frameJSON(payload: "not base64 !!!"))
        #expect(throws: ReceiveError.payloadNotBase64) { try frame.decodedEvent() }
    }

    @Test func rejectsBase64ThatIsNotAPublishedLanguageEvent() throws {
        let junk = Data(#"{"nope":true}"#.utf8).base64EncodedString()
        let frame = try ConsumerFrame(json: frameJSON(payload: junk))
        #expect(throws: (any Error).self) { try frame.decodedEvent() }
    }

    @Test func rejectsMalformedFrame() {
        #expect(throws: (any Error).self) { try ConsumerFrame(json: Data("not json".utf8)) }
    }

    /// Older brokers may omit redeliveryCount; absence means first delivery.
    @Test func defaultsRedeliveryCountWhenAbsent() throws {
        let json = Data(#"{"messageId":"m-1","payload":"e30="}"#.utf8)
        let frame = try ConsumerFrame(json: json)
        #expect(frame.redeliveryCount == 0)
        #expect(frame.properties.isEmpty)
    }

    @Test func recordReportsRedelivery() throws {
        let frame = try ConsumerFrame(json: frameJSON(payload: eventPayloadBase64, redeliveryCount: "3"))
        let record = ReceivedRecord(frame: frame, event: try frame.decodedEvent())
        #expect(record.redeliveryCount == 3)
        #expect(record.isRedelivery)
    }
}
