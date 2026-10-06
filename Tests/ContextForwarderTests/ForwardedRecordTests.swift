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

    // MARK: - decodeMetadata

    /// What a consuming context would declare: its own schema, nothing from the kit.
    private struct Operator: Decodable, Equatable {
        let operatorId: String
    }

    private struct LenientOperator: Decodable, Equatable {
        let operatorId: String?
    }

    private func record(metadata: Data?) -> ForwardedRecord {
        ForwardedRecord(
            eventType: "CollaboratorAdded", streamName: "s", eventId: "evt-42",
            data: Data(), metadata: metadata)
    }

    @Test("decodeMetadata decodes the bytes with the caller's type")
    func decodesMetadata() throws {
        let bytes = #"{"operatorId":"u-1"}"#.data(using: .utf8)!
        let decoded = try record(metadata: bytes).decodeMetadata(Operator.self)
        #expect(decoded == Operator(operatorId: "u-1"))
    }

    @Test("decodeMetadata returns nil when the record has no metadata")
    func absentMetadataIsNil() throws {
        let decoded = try record(metadata: nil).decodeMetadata(Operator.self)
        #expect(decoded == nil)
    }

    @Test("decodeMetadata ignores keys the caller's type does not declare")
    func unknownKeysAreIgnored() throws {
        let bytes = #"{"operatorId":"u-1","requestId":"r-9","tenant":"t"}"#.data(using: .utf8)!
        let decoded = try record(metadata: bytes).decodeMetadata(Operator.self)
        #expect(decoded == Operator(operatorId: "u-1"))
    }

    @Test("undecodable bytes are permanent and the reason names the record")
    func malformedBytesArePermanent() {
        let bytes = "not json".data(using: .utf8)!
        #expect {
            _ = try record(metadata: bytes).decodeMetadata(Operator.self)
        } throws: { error in
            guard case .permanent(let reason) = error as? ForwardingError else { return false }
            return reason.contains("CollaboratorAdded") && reason.contains("evt-42")
                && reason.contains("Operator")
        }
    }

    @Test("whitespace-only bytes are present-but-broken, so permanent, not nil")
    func whitespaceBytesArePermanent() {
        let bytes = "   \n".data(using: .utf8)!
        #expect(throws: ForwardingError.self) {
            _ = try record(metadata: bytes).decodeMetadata(Operator.self)
        }
    }

    @Test("non-UTF-8 bytes are permanent")
    func nonUTF8BytesArePermanent() {
        let bytes = Data([0xFF, 0xFE, 0x00])
        #expect(throws: ForwardingError.self) {
            _ = try record(metadata: bytes).decodeMetadata(Operator.self)
        }
    }

    @Test("a missing required field is permanent for a strict type")
    func missingRequiredFieldIsPermanent() {
        let bytes = #"{}"#.data(using: .utf8)!
        #expect(throws: ForwardingError.self) {
            _ = try record(metadata: bytes).decodeMetadata(Operator.self)
        }
    }

    @Test("the same bytes decode for a type that declares the field optional")
    func lenientTypeDecodesMissingField() throws {
        let bytes = #"{}"#.data(using: .utf8)!
        let decoded = try record(metadata: bytes).decodeMetadata(LenientOperator.self)
        #expect(decoded == LenientOperator(operatorId: nil))
    }
}
