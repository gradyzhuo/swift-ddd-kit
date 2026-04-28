import Testing
import KurrentSupport

@Suite("KurrentProjection.NackAction")
struct KurrentProjectionNackActionTests {

    @Test("All four nack actions are defined")
    func allCasesExist() {
        let cases: [KurrentProjection.NackAction] = [.retry, .skip, .park, .stop]
        #expect(cases.count == 4)
    }

    @Test("NackAction is Sendable")
    func isSendable() {
        // Compile-time check — sending across actor boundary requires Sendable.
        let _: any Sendable = KurrentProjection.NackAction.retry
    }
}
