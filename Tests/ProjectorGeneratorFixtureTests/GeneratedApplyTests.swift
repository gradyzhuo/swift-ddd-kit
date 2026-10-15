import Testing
import DDDKit
import ProjectorGeneratorFixture

@Suite("Generated projector apply()")
struct GeneratedApplyTests {
    @Test("An unlisted event in the middle of a batch does not drop the listed events after it")
    func unlistedEventInMiddle() throws {
        let projector = OrderSummaryProjector(store: .init())
        var model = OrderSummary(id: "o-1")
        let events: [any DomainEvent] = [
            OrderCreated(orderId: "o-1", customerId: "c-1", totalAmount: 100),
            OrderNoteAdded(orderId: "o-1", note: "not projected"),
            OrderAmountUpdated(orderId: "o-1", newAmount: 250),
        ]

        try projector.apply(readModel: &model, events: events)

        #expect(model.customerId == "c-1")
        #expect(model.totalAmount == 250)
    }
}
