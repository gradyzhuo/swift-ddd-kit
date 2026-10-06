import Foundation
import Testing
@testable import ContextForwarder

@Suite("ForwardedRecord")
struct ForwardedRecordTests {

    /// DDDKit-generated events encode `occurred` with a plain JSONEncoder
    /// (.deferredToDate → seconds since reference date).
    private func data(occurred: Date) -> Data {
        let seconds = occurred.timeIntervalSinceReferenceDate
        return #"{"occurred":\#(seconds),"who":"acc-1"}"#.data(using: .utf8)!
    }

    @Test("decodeOccurred reads the event's own timestamp")
    func decodesOccurred() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let record = ForwardedRecord(
            eventType: "X", streamName: "s", eventId: "e", data: data(occurred: when))

        let decoded = try record.decodeOccurred()
        #expect(abs(decoded.timeIntervalSince(when)) < 0.001)
    }

    @Test("decodeOccurred throws permanent when the event carries no timestamp")
    func missingOccurredIsPermanent() {
        let record = ForwardedRecord(
            eventType: "X", streamName: "s", eventId: "e",
            data: #"{"who":"acc-1"}"#.data(using: .utf8)!)

        #expect(throws: ForwardingError.self) { _ = try record.decodeOccurred() }
    }

    // MARK: - metadata field

    @Test("existing 4-argument init leaves metadata nil")
    func legacyInitHasNilMetadata() {
        let record = ForwardedRecord(
            eventType: "X", streamName: "s", eventId: "e", data: Data())
        #expect(record.metadata == nil)
    }

    @Test("init stores the metadata bytes it is given")
    func initStoresMetadata() {
        let bytes = #"{"operatorId":"u-1"}"#.data(using: .utf8)!
        let record = ForwardedRecord(
            eventType: "X", streamName: "s", eventId: "e", data: Data(), metadata: bytes)
        #expect(record.metadata == bytes)
    }

    @Test("normalizedMetadata turns KurrentDB's empty Data into nil")
    func emptyBytesNormaliseToNil() {
        #expect(ForwardedRecord.normalizedMetadata(Data()) == nil)
    }

    @Test("normalizedMetadata passes non-empty bytes through untouched")
    func nonEmptyBytesPassThrough() {
        let bytes = #"{"operatorId":"u-1"}"#.data(using: .utf8)!
        #expect(ForwardedRecord.normalizedMetadata(bytes) == bytes)
    }
}
