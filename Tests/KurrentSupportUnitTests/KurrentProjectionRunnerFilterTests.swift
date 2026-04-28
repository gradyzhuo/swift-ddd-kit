import Testing
import EventSourcing
@testable import KurrentSupport

@Suite("KurrentProjection runner filter integration")
struct KurrentProjectionRunnerFilterTests {

    private struct AllowList: EventTypeFilter {
        let allowed: Set<String>
        func handles(eventType: String) -> Bool { allowed.contains(eventType) }
    }

    @Test("nil filter passes every event type")
    func nilFilter() {
        #expect(KurrentProjection.PersistentSubscriptionRunner._shouldDispatchForTesting(
            eventType: "OrderCreated", filter: nil) == true)
        #expect(KurrentProjection.PersistentSubscriptionRunner._shouldDispatchForTesting(
            eventType: "anything", filter: nil) == true)
    }

    @Test("Filter accepts only listed event types")
    func filterAccepts() {
        let f = AllowList(allowed: ["A", "B"])
        #expect(KurrentProjection.PersistentSubscriptionRunner._shouldDispatchForTesting(
            eventType: "A", filter: f) == true)
        #expect(KurrentProjection.PersistentSubscriptionRunner._shouldDispatchForTesting(
            eventType: "B", filter: f) == true)
        #expect(KurrentProjection.PersistentSubscriptionRunner._shouldDispatchForTesting(
            eventType: "C", filter: f) == false)
    }
}
