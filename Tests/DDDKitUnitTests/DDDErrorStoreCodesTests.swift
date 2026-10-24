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

    @Test("streamPurged carries the id")
    func streamPurgedPayload() {
        let error = DDDError.streamPurged(id: "o-1")
        #expect(error.code == .streamPurged)
        #expect(error.userInfos["id"] as? String == "o-1")
    }
}
