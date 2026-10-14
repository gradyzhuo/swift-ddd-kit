import Testing
import Foundation
@testable import DomainEventGenerator

@Suite("ProjectorGenerator")
struct ProjectorGeneratorTests {

    private func render(_ yaml: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("projection-\(UUID().uuidString).yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try ProjectorGenerator(projectionModelYamlFileURL: url)
            .render(accessLevel: .internal)
            .joined(separator: "\n")
    }

    @Test("apply() skips an unlisted event (continue) instead of returning out of the whole fold")
    func unlistedEventContinues() throws {
        let output = try render("""
            OrderSummary:
              model: readModel
              events:
                - OrderCreated
                - OrderAmountUpdated
            """)
        #expect(output.contains("default:\n                continue"))
        #expect(!output.contains("default:\n                return"))
    }
}
