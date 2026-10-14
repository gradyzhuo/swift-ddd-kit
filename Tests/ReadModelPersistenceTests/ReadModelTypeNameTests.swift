import Testing
import EventSourcing

private struct DefaultNamed: ReadModel, Sendable {
    let id: String
}

private struct StablyNamed: ReadModel, Sendable {
    static var readModelTypeName: String { "OrderSummary.v1" }
    let id: String
}

@Suite("ReadModel.readModelTypeName")
struct ReadModelTypeNameTests {
    @Test("Defaults to the Swift type name, matching the pre-existing stored `type` value")
    func defaultsToTypeName() {
        #expect(DefaultNamed.readModelTypeName == "DefaultNamed")
    }

    @Test("A read model can declare a stable name that survives Swift renames")
    func customName() {
        #expect(StablyNamed.readModelTypeName == "OrderSummary.v1")
    }

    @Test("Reachable through an existential metatype (used by rebuild)")
    func existentialMetatype() {
        let types: [any ReadModel.Type] = [DefaultNamed.self, StablyNamed.self]
        #expect(types.map { $0.readModelTypeName } == ["DefaultNamed", "OrderSummary.v1"])
    }
}
