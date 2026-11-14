import Testing
import Foundation
import EventSourcing
import KurrentSupport

private struct StubRecord: RecordedEventLike {
    var id = UUID()
    var eventType = "QuoteOpened"
    var revision: UInt64 = 4
    var customMetadata: Data
    var streamName = "Quoting-q-1"

    func decode<T: Decodable>(to type: T.Type) throws -> T? {
        try JSONDecoder().decode(type, from: Data(#"{"line":"desk"}"#.utf8))
    }
}

private struct Line: Decodable, Equatable {
    let line: String
}

@Suite("Custom metadata holding only the server's $schema.* keys")
struct ServerSchemaMetadataTests {
    @Test(
        "only a JSON object whose keys are exactly $schema.name and $schema.format counts as the server's",
        arguments: [
            (#"{"$schema.name":"QuoteOpened","$schema.format":"Json"}"#, true),
            (#" { "$schema.format" : "Json", "$schema.name" : "QuoteOpened" } "#, true),
            (#"{"$schema.name":"QuoteOpened"}"#, false),
            (#"{"$schema.note":"mine"}"#, false),
            (#"{"$schema.note":"mine","$schema.format":"Json"}"#, false),
            (#"{"$schema.name":"QuoteOpened","$schema.format":"Json","$schema.note":"mine"}"#, false),
            (#"{"$schema.name":"QuoteOpened","operatorId":"op-7"}"#, false),
            (#"{"operatorId":"op-7"}"#, false),
            (#"{}"#, false),
            (#"["$schema.name"]"#, false),
            (#""$schema.name""#, false),
            ("", false),
            ("not json", false),
        ]
    )
    func detection(bytes: String, expected: Bool) {
        #expect(holdsOnlyServerSchemaKeys(Data(bytes.utf8)) == expected)
    }

    @Test("such a record is handed on with empty custom metadata and everything else unchanged")
    func schemaOnlyMetadataBecomesEmpty() throws {
        let original = StubRecord(customMetadata: Data(#"{"$schema.name":"QuoteOpened","$schema.format":"Json"}"#.utf8))
        let record = withoutServerOnlyMetadata(original)
        #expect(record.customMetadata.isEmpty)
        #expect(record.id == original.id)
        #expect(record.eventType == original.eventType)
        #expect(record.revision == original.revision)
        #expect(record.streamName == original.streamName)
        #expect(try record.decode(to: Line.self) == Line(line: "desk"))
    }

    @Test("a record with metadata of its own is handed on as it is, server keys included")
    func ownMetadataIsKept() {
        let bytes = Data(#"{"operatorId":"op-7","$schema.name":"QuoteOpened","$schema.format":"Json"}"#.utf8)
        #expect(withoutServerOnlyMetadata(StubRecord(customMetadata: bytes)).customMetadata == bytes)
    }
}
