import Testing
import KurrentSupport

@Suite("KurrentProjection.RunnerStopped")
struct KurrentProjectionRunnerStoppedTests {

    @Test("RunnerStopped carries a reason string")
    func carriesReason() {
        let error = KurrentProjection.RunnerStopped(reason: "test reason")
        #expect(error.reason == "test reason")
    }

    @Test("RunnerStopped conforms to Error")
    func conformsToError() {
        let error: any Error = KurrentProjection.RunnerStopped(reason: "x")
        #expect(error is KurrentProjection.RunnerStopped)
    }
}
