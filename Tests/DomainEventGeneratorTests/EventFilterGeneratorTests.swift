import Testing
@testable import DomainEventGenerator

@Suite("EventFilterGenerator")
struct EventFilterGeneratorTests {

    @Test("Renders an internal struct conforming to EventTypeFilter with a switch")
    func rendersInternalStruct() {
        let generator = EventFilterGenerator(
            modelName: "OrderSummary",
            eventNames: ["OrderCreated", "OrderAmountUpdated", "OrderCancelled"]
        )
        let output = generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(output.contains("internal struct OrderSummaryEventFilter: EventTypeFilter"))
        #expect(output.contains("internal init()"))
        #expect(output.contains("internal func handles(eventType: String) -> Bool"))
        #expect(output.contains(#""OrderCreated""#))
        #expect(output.contains(#""OrderAmountUpdated""#))
        #expect(output.contains(#""OrderCancelled""#))
        #expect(output.contains("default:"))
        #expect(output.contains("return true"))
        #expect(output.contains("return false"))
    }

    @Test("Public access level emits public struct")
    func publicAccess() {
        let generator = EventFilterGenerator(modelName: "X", eventNames: ["E"])
        let output = generator.render(accessLevel: .public).joined(separator: "\n")
        #expect(output.contains("public struct XEventFilter"))
        #expect(output.contains("public init()"))
        #expect(output.contains("public func handles(eventType: String) -> Bool"))
    }

    @Test("Empty event list still emits valid struct (default returns false)")
    func emptyEventList() {
        let generator = EventFilterGenerator(modelName: "Empty", eventNames: [])
        let output = generator.render(accessLevel: .internal).joined(separator: "\n")
        #expect(output.contains("internal struct EmptyEventFilter: EventTypeFilter"))
        #expect(output.contains("default:"))
        #expect(output.contains("return false"))
    }
}
