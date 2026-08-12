import Foundation
import Testing
@testable import ContextForwarder

@Suite("Error classification")
struct ForwardingErrorTests {

    struct Transient: Error {}

    @Test("explicit permanent errors park")
    func permanentParks() {
        #expect(ForwardingDisposition(for: ForwardingError.permanent(reason: "bad payload")) == .park)
    }

    @Test("unknown errors retry — transient is the safe default")
    func unknownRetries() {
        #expect(ForwardingDisposition(for: Transient()) == .retry)
    }

    @Test("decode failures are permanent: a malformed payload never decodes")
    func decodeFailureIsPermanent() {
        struct Body: Decodable { let required: String }
        let record = ForwardedRecord(
            eventType: "X", streamName: "s", eventId: "e",
            data: #"{"other":1}"#.data(using: .utf8)!)

        #expect(throws: ForwardingError.self) { _ = try record.decodeBody(Body.self) }
        do {
            _ = try record.decodeBody(Body.self)
        } catch {
            #expect(ForwardingDisposition(for: error) == .park)
        }
    }
}
