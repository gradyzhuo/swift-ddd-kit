import Foundation
import Testing
@testable import ContextReceiver

/// Key order from `JSONEncoder` is not guaranteed, so these assert by
/// decoding the produced JSON and checking fields, not by string equality.
@Suite("Consumer wire commands")
struct ConsumerCommandTests {
    private struct Decoded: Decodable {
        let messageId: String?
        let type: String?
        let permitMessages: Int?
    }

    private func decode(_ json: String) throws -> Decoded {
        try JSONDecoder().decode(Decoded.self, from: Data(json.utf8))
    }

    @Test func ackSendsOnlyMessageId() throws {
        let decoded = try decode(ConsumerCommand.ack(messageId: "CAAQAw==").json)
        #expect(decoded.messageId == "CAAQAw==")
        #expect(decoded.type == nil)
        #expect(decoded.permitMessages == nil)
    }

    @Test func negativeAcknowledgeCarriesTypeAndMessageId() throws {
        let decoded = try decode(ConsumerCommand.negativeAcknowledge(messageId: "CAAQAw==").json)
        #expect(decoded.type == "negativeAcknowledge")
        #expect(decoded.messageId == "CAAQAw==")
        #expect(decoded.permitMessages == nil)
    }

    @Test func permitCarriesTypeAndCount() throws {
        let decoded = try decode(ConsumerCommand.permit(count: 100).json)
        #expect(decoded.type == "permit")
        #expect(decoded.permitMessages == 100)
        #expect(decoded.messageId == nil)
    }
}
