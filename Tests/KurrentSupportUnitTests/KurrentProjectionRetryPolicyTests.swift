import Testing
import KurrentSupport

@Suite("KurrentProjection.MaxRetriesPolicy")
struct KurrentProjectionRetryPolicyTests {

    private struct DummyError: Error {}

    @Test("Returns .retry when retryCount < max")
    func retriesWhenUnderLimit() {
        let policy = KurrentProjection.MaxRetriesPolicy(max: 5)
        let action = policy.decide(error: DummyError(), retryCount: 0)
        #expect(action == .retry)
    }

    @Test("Returns .retry when retryCount is one below max")
    func retriesAtMaxMinusOne() {
        let policy = KurrentProjection.MaxRetriesPolicy(max: 5)
        #expect(policy.decide(error: DummyError(), retryCount: 4) == .retry)
    }

    @Test("Returns .skip when retryCount equals max")
    func skipsAtMax() {
        let policy = KurrentProjection.MaxRetriesPolicy(max: 5)
        #expect(policy.decide(error: DummyError(), retryCount: 5) == .skip)
    }

    @Test("Returns .skip when retryCount exceeds max")
    func skipsAboveMax() {
        let policy = KurrentProjection.MaxRetriesPolicy(max: 5)
        #expect(policy.decide(error: DummyError(), retryCount: 100) == .skip)
    }

    @Test("Default max is 5")
    func defaultMaxIsFive() {
        let policy = KurrentProjection.MaxRetriesPolicy()
        #expect(policy.max == 5)
    }

    @Test("NackAction equality works for assertions")
    func nackActionIsEquatable() {
        let a: KurrentProjection.NackAction = .retry
        let b: KurrentProjection.NackAction = .retry
        #expect(a == b)
    }
}
