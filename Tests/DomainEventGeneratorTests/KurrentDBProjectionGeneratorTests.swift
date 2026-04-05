import Testing
import Foundation
@testable import DomainEventGenerator

@Suite("KurrentDBProjectionGenerator")
struct KurrentDBProjectionGeneratorTests {

    @Test("definition without category returns nil")
    func noCategoryReturnsNil() throws {
        let definition = EventProjectionDefinition(
            model: .readModel,
            kurrentDBEvents: [.plain("OrderCreated")]
        )
        let generator = KurrentDBProjectionGenerator(name: "MyModel", definition: definition)
        let result = try generator.render()
        #expect(result == nil)
    }

    @Test("standard routing generates correct fromStreams and linkTo")
    func standardRoutingGeneratesJS() throws {
        let definition = EventProjectionDefinition(
            model: .readModel,
            category: "Quotation",
            idField: "quotingCaseId",
            kurrentDBEvents: [.plain("QuotationCreated"), .plain("QuotationUpdated")]
        )
        let generator = KurrentDBProjectionGenerator(name: "OC_GetQuotation", definition: definition)
        let js = try #require(try generator.render())
        #expect(js.contains(#"fromStreams(["$ce-Quotation"])"#))
        #expect(js.contains("QuotationCreated: function(state, event)"))
        #expect(js.contains("QuotationUpdated: function(state, event)"))
        #expect(js.contains(#"linkTo("OC_GetQuotation-" + event.body["quotingCaseId"], event)"#))
    }

    @Test("custom handler body is embedded verbatim inside wrapper")
    func customHandlerEmbeddedVerbatim() throws {
        let body = #"linkTo("OtherTarget-" + event.body.otherId, event);"#
        let definition = EventProjectionDefinition(
            model: .readModel,
            category: "Quotation",
            kurrentDBEvents: [.custom(name: "QuotationReassigned", body: body)]
        )
        let generator = KurrentDBProjectionGenerator(name: "OC_GetQuotation", definition: definition)
        let js = try #require(try generator.render())
        #expect(js.contains("QuotationReassigned: function(state, event)"))
        #expect(js.contains(body))
    }

    @Test("mixed list generates both standard and custom handlers")
    func mixedListGeneratesBoth() throws {
        let definition = EventProjectionDefinition(
            model: .readModel,
            category: "Order",
            idField: "orderId",
            kurrentDBEvents: [
                .plain("OrderCreated"),
                .custom(name: "OrderReassigned",
                        body: #"linkTo("T-" + event.body.newId, event);"#)
            ]
        )
        let generator = KurrentDBProjectionGenerator(name: "MyModel", definition: definition)
        let js = try #require(try generator.render())
        #expect(js.contains(#"linkTo("MyModel-" + event.body["orderId"], event)"#))
        #expect(js.contains(#"linkTo("T-" + event.body.newId, event);"#))
    }

    @Test("plain event without idField throws missingIdFieldForPlainEvent")
    func plainEventWithoutIdFieldThrows() throws {
        let definition = EventProjectionDefinition(
            model: .readModel,
            category: "Order",
            kurrentDBEvents: [.plain("OrderCreated")]
        )
        let generator = KurrentDBProjectionGenerator(name: "MyModel", definition: definition)
        #expect(throws: KurrentDBProjectionError.missingIdFieldForPlainEvent(modelName: "MyModel", eventName: "OrderCreated")) {
            _ = try generator.render()
        }
    }

    @Test("createdKurrentDBEvents appear before kurrentDBEvents in generated JS")
    func createdEventsAppearFirst() throws {
        let definition = EventProjectionDefinition(
            model: .readModel,
            category: "Order",
            idField: "orderId",
            kurrentDBEvents: [.plain("OrderUpdated")],
            createdKurrentDBEvents: [.plain("OrderCreated")]
        )
        let generator = KurrentDBProjectionGenerator(name: "MyModel", definition: definition)
        let js = try #require(try generator.render())
        let createdRange = try #require(js.range(of: "OrderCreated"))
        let updatedRange = try #require(js.range(of: "OrderUpdated"))
        #expect(createdRange.lowerBound < updatedRange.lowerBound)
    }

    @Test("output includes isJson guard for every handler")
    func outputIncludesIsJsonGuard() throws {
        let definition = EventProjectionDefinition(
            model: .readModel,
            category: "Order",
            idField: "orderId",
            kurrentDBEvents: [.plain("OrderCreated")]
        )
        let generator = KurrentDBProjectionGenerator(name: "MyModel", definition: definition)
        let js = try #require(try generator.render())
        #expect(js.contains("event.isJson"))
    }

    @Test("output contains $init handler")
    func outputContainsInitHandler() throws {
        let definition = EventProjectionDefinition(
            model: .readModel,
            category: "Order",
            idField: "orderId",
            kurrentDBEvents: [.plain("OrderCreated")]
        )
        let generator = KurrentDBProjectionGenerator(name: "MyModel", definition: definition)
        let js = try #require(try generator.render())
        #expect(js.contains("$init: function()"))
    }
}

@Suite("KurrentDBProjectionFileGenerator")
struct KurrentDBProjectionFileGeneratorTests {

    @Test("fileGeneratorWritesJsFile — writes correct JS file for definition with category")
    func fileGeneratorWritesJsFile() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KurrentDBProjectionFileGeneratorTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let yamlContent = """
        OC_GetOrder:
          model: readModel
          category: Order
          idField: orderId
          events:
            - OrderCreated
            - OrderUpdated
        """
        let yamlFileURL = tmpDir.appendingPathComponent("projection-model.yaml")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try yamlContent.write(to: yamlFileURL, atomically: true, encoding: .utf8)

        let outputDir = tmpDir.appendingPathComponent("output")
        let generator = try KurrentDBProjectionFileGenerator(projectionModelYamlFileURL: yamlFileURL)
        try generator.writeFiles(to: outputDir)

        let jsFileURL = outputDir.appendingPathComponent("OC_GetOrderProjection.js")
        #expect(FileManager.default.fileExists(atPath: jsFileURL.path))
        let jsContent = try String(contentsOf: jsFileURL, encoding: .utf8)
        #expect(jsContent.contains(#"fromStreams(["$ce-Order"])"#))
        #expect(jsContent.contains("OrderCreated: function(state, event)"))
        #expect(jsContent.contains("OrderUpdated: function(state, event)"))
        #expect(jsContent.contains(#"linkTo("OC_GetOrder-" + event.body["orderId"], event)"#))
    }

    @Test("fileGeneratorSkipsDefinitionsWithoutCategory — no JS file written when category absent")
    func fileGeneratorSkipsDefinitionsWithoutCategory() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KurrentDBProjectionFileGeneratorTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let yamlContent = """
        NoCategoryModel:
          model: readModel
          events:
            - SomeEvent
        """
        let yamlFileURL = tmpDir.appendingPathComponent("projection-model.yaml")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try yamlContent.write(to: yamlFileURL, atomically: true, encoding: .utf8)

        let outputDir = tmpDir.appendingPathComponent("output")
        let generator = try KurrentDBProjectionFileGenerator(projectionModelYamlFileURL: yamlFileURL)
        try generator.writeFiles(to: outputDir)

        let jsFileURL = outputDir.appendingPathComponent("NoCategoryModelProjection.js")
        #expect(!FileManager.default.fileExists(atPath: jsFileURL.path))
    }

    @Test("createdEvents appear before events in written JS file")
    func fileGeneratorCreatedEventsAppearFirst() throws {
        let yaml = """
        OrderModel:
          model: readModel
          category: Order
          idField: orderId
          createdEvents:
            - OrderCreated
          events:
            - OrderUpdated
        """
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let yamlFile = tmpDir.appendingPathComponent("model.yaml")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try yaml.write(to: yamlFile, atomically: true, encoding: .utf8)

        let outputDir = tmpDir.appendingPathComponent("out")
        let generator = try KurrentDBProjectionFileGenerator(projectionModelYamlFileURL: yamlFile)
        try generator.writeFiles(to: outputDir)

        let jsFile = outputDir.appendingPathComponent("OrderModelProjection.js")
        let js = try String(contentsOf: jsFile, encoding: .utf8)

        let createdRange = try #require(js.range(of: "OrderCreated"))
        let updatedRange = try #require(js.range(of: "OrderUpdated"))
        #expect(createdRange.lowerBound < updatedRange.lowerBound)
    }

    @Test("fileGeneratorCreatesOutputDirectory — output directory is created when absent")
    func fileGeneratorCreatesOutputDirectory() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KurrentDBProjectionFileGeneratorTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let yamlContent = """
        OrderModel:
          model: readModel
          category: Order
          idField: orderId
          events:
            - OrderCreated
        """
        let yamlFileURL = tmpDir.appendingPathComponent("projection-model.yaml")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try yamlContent.write(to: yamlFileURL, atomically: true, encoding: .utf8)

        let outputDir = tmpDir.appendingPathComponent("nested/output/dir")
        #expect(!FileManager.default.fileExists(atPath: outputDir.path))

        let generator = try KurrentDBProjectionFileGenerator(projectionModelYamlFileURL: yamlFileURL)
        try generator.writeFiles(to: outputDir)

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: outputDir.path, isDirectory: &isDirectory)
        #expect(exists && isDirectory.boolValue)
    }
}
