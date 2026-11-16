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

    @Test("a model file that does not decode is an error, not an empty output")
    func undecodableFileThrows() {
        #expect(throws: DecodingError.self) {
            try render("""
                OrderSummary:
                  model: readModel
                  createdEvent: OrderCreated
                  events:
                    - OrderAmountUpdated
                """)
        }
    }

    @Test("a model file with no YAML document renders no models", arguments: ["", "# no models yet\n"])
    func emptyFileRendersNothing(yaml: String) throws {
        #expect(try !render(yaml).contains("protocol"))
    }
}
