import Testing
import EventSourcing

@Suite("EventTypeFilter")
struct EventTypeFilterTests {

    private struct AcceptList: EventTypeFilter {
        let allowed: Set<String>
        func handles(eventType: String) -> Bool { allowed.contains(eventType) }
    }

    @Test("Custom filter handles only listed types")
    func customFilterMatches() {
        let filter = AcceptList(allowed: ["A", "B"])
        #expect(filter.handles(eventType: "A") == true)
        #expect(filter.handles(eventType: "B") == true)
        #expect(filter.handles(eventType: "C") == false)
    }

    @Test("Empty allow-list rejects everything")
    func emptyAllowList() {
        let filter = AcceptList(allowed: [])
        #expect(filter.handles(eventType: "anything") == false)
    }

    @Test("Filter is Sendable")
    func isSendable() {
        let _: any Sendable = AcceptList(allowed: ["x"])
    }
}
