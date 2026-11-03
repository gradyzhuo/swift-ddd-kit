import Testing
@testable import DDDCore

@Suite("DDDError store codes")
struct DDDErrorStoreCodesTests {

    @Test("store codes are 501–504")
    func rawValues() {
        #expect(DDDError.Code.commitConflict.rawValue == 501)
        #expect(DDDError.Code.streamPurged.rawValue == 502)
        #expect(DDDError.Code.storeUnavailable.rawValue == 503)
        #expect(DDDError.Code.storeCorrupted.rawValue == 504)
    }

    @Test("commitConflict carries id, expected and actual")
    func commitConflictPayload() {
        let error = DDDError.commitConflict(id: "o-1", expected: nil, actual: 3)
        #expect(error.code == .commitConflict)
        #expect(error.commitConflict == DDDError.CommitConflict(id: "o-1", expected: nil, actual: 3))
    }

    @Test("commitConflict accessor is nil for other codes")
    func accessorNilForOtherCodes() {
        #expect(DDDError.streamPurged(id: "o-1").commitConflict == nil)
    }

    @Test("commitConflict(conflicts:) exposes all conflicts and the first as commitConflict")
    func multiConflict() {
        let a = DDDError.CommitConflict(id: "q-1", expected: nil, actual: 0)
        let b = DDDError.CommitConflict(id: "b-1", expected: 3, actual: 4)
        let error = DDDError.commitConflict(conflicts: [a, b])
        #expect(error.code == .commitConflict)
        #expect(error.commitConflicts == [a, b])
        #expect(error.commitConflict == a)
    }

    @Test("commitConflict(conflicts:) names every conflicting id in its message")
    func multiConflictMessage() {
        let error = DDDError.commitConflict(conflicts: [
            DDDError.CommitConflict(id: "q-1", expected: nil, actual: 0),
            DDDError.CommitConflict(id: "b-1", expected: 3, actual: 4),
        ])
        #expect(error.message == "[commitConflict] Append to q-1, b-1 found other revisions.")
    }

    @Test("single commitConflict reports itself in commitConflicts; other codes report none")
    func singleAndOthers() {
        #expect(DDDError.commitConflict(id: "o-1", expected: nil, actual: 3).commitConflicts.count == 1)
        #expect(DDDError.commitConflict(id: "o-1", expected: nil, actual: 3).commitConflicts
            == [DDDError.CommitConflict(id: "o-1", expected: nil, actual: 3)])
        #expect(DDDError.streamPurged(id: "o-1").commitConflicts.isEmpty)
    }

    @Test("streamPurged carries the id")
    func streamPurgedPayload() {
        let error = DDDError.streamPurged(id: "o-1")
        #expect(error.code == .streamPurged)
        #expect(error.userInfos["id"] as? String == "o-1")
    }

    @Test("storeUnavailable carries reason, path and detail")
    func storeUnavailablePayload() {
        let error = DDDError.storeUnavailable(reason: .occupied, path: "/tmp/store", detail: "EWOULDBLOCK")
        #expect(error.code == .storeUnavailable)
        #expect(error.storeUnavailableReason == .occupied)
        #expect(error.userInfos["path"] as? String == "/tmp/store")
        #expect(error.userInfos["detail"] as? String == "EWOULDBLOCK")
        #expect(DDDError.storeCorrupted(stream: "Order-1").storeUnavailableReason == nil)
    }

    @Test("storeCorrupted carries the stream name")
    func storeCorruptedPayload() {
        let error = DDDError.storeCorrupted(stream: "Order-1")
        #expect(error.code == .storeCorrupted)
        #expect(error.corruptedStream == "Order-1")
        #expect(DDDError.streamPurged(id: "o-1").corruptedStream == nil)
    }
}
