import Foundation
import Testing
import DDDCore
@testable import LocalEventStore

@Suite("StreamFile")
struct StreamFileTests {

    private func hex(_ name: String) -> String {
        name.utf8.map { byte in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
    }

    @Test("file name is the lowercase hex of the UTF-8 stream name")
    func fileNameIsLowercaseHex() throws {
        for name in ["Order-1", "Order-A", "Order-a", "訂單-42", "a/b\\c:d"] {
            #expect(try StreamFile.fileName(forStream: name) == hex(name) + ".json")
        }
        #expect(try StreamFile.fileName(forStream: "AZ") == "415a.json")
    }

    @Test("names longer than 120 UTF-8 bytes are rejected")
    func tooLongNamesAreRejected() throws {
        let longest = String(repeating: "x", count: 120)
        #expect(try StreamFile.fileName(forStream: longest).count == 240 + 5)

        do {
            _ = try StreamFile.fileName(forStream: longest + "x")
            Issue.record("expected streamNameTooLong")
        } catch let error as DDDError {
            #expect(error.storeUnavailableReason == .streamNameTooLong)
        }
    }

    @Test("records omit metadata when there is none")
    func encodingOmitsMissingMetadata() throws {
        let file = StreamFile(
            stream: "Order-1",
            records: [.init(eventId: UUID(), eventType: "OrderCreated", payload: Data("{}".utf8), metadata: nil)]
        )
        let json = String(decoding: try StreamFile.encode(file), as: UTF8.self)
        #expect(json.contains("\"formatVersion\":1"))
        #expect(json.contains("\"purged\":false"))
        #expect(!json.contains("\"metadata\""))
        #expect(try JSONDecoder().decode(StreamFile.self, from: StreamFile.encode(file)) == file)
    }
}
