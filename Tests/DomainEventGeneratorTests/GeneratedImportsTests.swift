import Testing
@testable import DomainEventGenerator

@Suite("Generated file imports")
struct GeneratedImportsTests {

    private func imports(_ dependencies: [String]) -> [String] {
        HeaderGenerator(dependencies: dependencies).render().filter { $0.hasPrefix("import ") }
    }

    @Test("event files import EventSourcing, not KurrentSupport")
    func eventImports() {
        #expect(imports(GeneratedImports.event) == ["import Foundation", "import DDDCore", "import EventSourcing"])
    }

    @Test("event mapper files import EventSourcing, not KurrentSupport or KurrentDB")
    func eventMapperImports() {
        #expect(imports(GeneratedImports.eventMapper) == ["import Foundation", "import DDDCore", "import EventSourcing"])
    }

    @Test("projection model files are unchanged")
    func projectionModelImports() {
        #expect(imports(GeneratedImports.projectionModel) == ["import Foundation", "import DDDCore", "import EventSourcing"])
    }
}
