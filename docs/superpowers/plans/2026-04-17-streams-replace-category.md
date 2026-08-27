# Replace `category` with `streams` in KurrentDB Projection Generator

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single `category: String?` field in `EventProjectionDefinition` with `streams: [String]?`, allowing projections to listen to multiple full stream names directly (e.g. `$ce-Order`) instead of auto-prefixing a single category name.

**Architecture:** `EventProjectionDefinition` loses `category`, gains `streams`. `KurrentDBProjectionGenerator.render()` joins all stream names verbatim into `fromStreams([...])`. YAML callers write full stream names (e.g. `$ce-Order`) instead of bare category names.

**Tech Stack:** Swift, Yams (YAML decoder), Swift Testing (`@Test`/`#expect`)

---

## File Map

| Action | File |
|--------|------|
| Modify | `Sources/DomainEventGenerator/EventProjectionDefinition.swift` |
| Modify | `Sources/DomainEventGenerator/Generator/Model/KurrentDBProjectionGenerator.swift` |
| Modify | `Tests/DomainEventGeneratorTests/KurrentDBProjectionParsingTests.swift` |
| Modify | `Tests/DomainEventGeneratorTests/KurrentDBProjectionGeneratorTests.swift` |

---

## Task 1: Write new failing tests for `streams`

Add tests for the new `streams` field behavior before touching production code. These will fail to compile until Task 2 is done.

**Files:**
- Modify: `Tests/DomainEventGeneratorTests/KurrentDBProjectionParsingTests.swift`
- Modify: `Tests/DomainEventGeneratorTests/KurrentDBProjectionGeneratorTests.swift`

- [ ] **Step 1: Add multi-stream parsing test to `KurrentDBProjectionParsingTests.swift`**

Add this test inside `struct KurrentDBProjectionParsingTests`:

```swift
@Test("multiple streams decode correctly")
func multipleStreamsDecodes() throws {
    let yaml = """
    MyModel:
      model: readModel
      streams:
        - $ce-Order
        - $ce-OrderItem
      idField: orderId
      events:
        - OrderCreated
    """
    let decoder = YAMLDecoder()
    let definitions = try decoder.decode([String: EventProjectionDefinition].self, from: yaml)
    let def = try #require(definitions["MyModel"])
    #expect(def.streams == ["$ce-Order", "$ce-OrderItem"])
}
```

- [ ] **Step 2: Add multi-stream generation test to `KurrentDBProjectionGeneratorTests.swift`**

Add this test inside `struct KurrentDBProjectionGeneratorTests`:

```swift
@Test("multiple streams generates correct fromStreams")
func multipleStreamsGeneratesCorrectFromStreams() throws {
    let definition = EventProjectionDefinition(
        model: .readModel,
        streams: ["$ce-Order", "$ce-OrderItem"],
        idField: "orderId",
        kurrentDBEvents: [.plain("OrderCreated")]
    )
    let generator = KurrentDBProjectionGenerator(name: "MyModel", definition: definition)
    let js = try #require(try generator.render())
    #expect(js.contains(#"fromStreams(["$ce-Order", "$ce-OrderItem"])"#))
}
```

- [ ] **Step 3: Verify tests fail to compile**

```bash
cd /Volumes/Development/swift-ddd-kit && swift build --build-tests 2>&1 | grep -E "error:|streams"
```

Expected: compile error referencing `streams` — `EventProjectionDefinition` has no such member yet.

---

## Task 2: Replace `category` with `streams` in `EventProjectionDefinition`

**Files:**
- Modify: `Sources/DomainEventGenerator/EventProjectionDefinition.swift`

- [ ] **Step 1: Replace the stored property declaration**

In `EventProjectionDefinition.swift`, replace:
```swift
// KurrentDB projection fields
package let category: String?
package let idField: String?
```
with:
```swift
// KurrentDB projection fields
package let streams: [String]?
package let idField: String?
```

- [ ] **Step 2: Replace the memberwise initializer parameter**

Replace:
```swift
package init(
    idType: PropertyDefinition.PropertyType = .string,
    model: ModelKind,
    category: String? = nil,
    idField: String? = nil,
    kurrentDBEvents: [KurrentDBProjectionEventItem] = [],
    createdKurrentDBEvents: [KurrentDBProjectionEventItem] = [],
    deletedEvent: String? = nil
) {
    self.idType = idType
    self.model = model
    self.category = category
    self.idField = idField
    self.kurrentDBEvents = kurrentDBEvents
    self.createdKurrentDBEvents = createdKurrentDBEvents
    self.deletedEvent = deletedEvent
}
```
with:
```swift
package init(
    idType: PropertyDefinition.PropertyType = .string,
    model: ModelKind,
    streams: [String]? = nil,
    idField: String? = nil,
    kurrentDBEvents: [KurrentDBProjectionEventItem] = [],
    createdKurrentDBEvents: [KurrentDBProjectionEventItem] = [],
    deletedEvent: String? = nil
) {
    self.idType = idType
    self.model = model
    self.streams = streams
    self.idField = idField
    self.kurrentDBEvents = kurrentDBEvents
    self.createdKurrentDBEvents = createdKurrentDBEvents
    self.deletedEvent = deletedEvent
}
```

- [ ] **Step 3: Replace decode logic in `init(from decoder:)`**

Replace:
```swift
let category = try container.decodeIfPresent(String.self, forKey: .category)
let idField = try container.decodeIfPresent(String.self, forKey: .idField)
```
with:
```swift
let streams = try container.decodeIfPresent([String].self, forKey: .streams)
let idField = try container.decodeIfPresent(String.self, forKey: .idField)
```

And replace:
```swift
self.init(
    idType: idType,
    model: model,
    category: category,
    idField: idField,
    kurrentDBEvents: kurrentDBEvents,
    createdKurrentDBEvents: createdKurrentDBEvents,
    deletedEvent: deletedEvent
)
```
with:
```swift
self.init(
    idType: idType,
    model: model,
    streams: streams,
    idField: idField,
    kurrentDBEvents: kurrentDBEvents,
    createdKurrentDBEvents: createdKurrentDBEvents,
    deletedEvent: deletedEvent
)
```

- [ ] **Step 4: Replace encode logic in `encode(to encoder:)`**

Replace:
```swift
try container.encodeIfPresent(category, forKey: .category)
```
with:
```swift
try container.encodeIfPresent(streams, forKey: .streams)
```

- [ ] **Step 5: Replace the CodingKey case**

Replace:
```swift
private enum CodingKeys: String, CodingKey {
    case idType, model, deletedEvent, category, idField
    case events
    case createdEvents
}
```
with:
```swift
private enum CodingKeys: String, CodingKey {
    case idType, model, deletedEvent, streams, idField
    case events
    case createdEvents
}
```

---

## Task 3: Update `KurrentDBProjectionGenerator` to use `streams`

**Files:**
- Modify: `Sources/DomainEventGenerator/Generator/Model/KurrentDBProjectionGenerator.swift`

- [ ] **Step 1: Replace the `render()` guard and `fromStreams` line**

Replace:
```swift
guard let category = definition.category else { return nil }

var lines: [String] = []
lines.append(#"fromStreams(["$ce-\#(category)"])"#)
```
with:
```swift
guard let streams = definition.streams, !streams.isEmpty else { return nil }

var lines: [String] = []
let streamList = streams.map { "\"\($0)\"" }.joined(separator: ", ")
lines.append("fromStreams([\(streamList)])")
```

- [ ] **Step 2: Verify the project builds**

```bash
cd /Volumes/Development/swift-ddd-kit && swift build 2>&1 | grep -E "error:|warning:"
```

Expected: compile errors only in test files (still reference `category:`). No errors in production code.

---

## Task 4: Update existing tests — replace `category` with `streams`

All existing tests used `category: "Order"` or YAML `category: Order`. Replace every occurrence with `streams: ["$ce-Order"]` (initializer) or `streams:\n  - $ce-Order` (YAML).

**Files:**
- Modify: `Tests/DomainEventGeneratorTests/KurrentDBProjectionParsingTests.swift`
- Modify: `Tests/DomainEventGeneratorTests/KurrentDBProjectionGeneratorTests.swift`

### KurrentDBProjectionParsingTests.swift

- [ ] **Step 1: Update `plainStringEventDecodes()`**

Replace YAML `category: Order` → `streams:\n        - $ce-Order` and update the assertion:

```swift
@Test("plain string event decodes correctly")
func plainStringEventDecodes() throws {
    let yaml = """
    MyModel:
      model: readModel
      streams:
        - $ce-Order
      idField: orderId
      events:
        - OrderCreated
    """
    let decoder = YAMLDecoder()
    let definitions = try decoder.decode([String: EventProjectionDefinition].self, from: yaml)
    let def = try #require(definitions["MyModel"])
    #expect(def.streams == ["$ce-Order"])
    #expect(def.idField == "orderId")
    #expect(def.kurrentDBEvents.count == 1)
    guard case .plain(let name) = def.kurrentDBEvents[0] else {
        Issue.record("Expected .plain, got \(def.kurrentDBEvents[0])")
        return
    }
    #expect(name == "OrderCreated")
}
```

- [ ] **Step 2: Update `customHandlerEventDecodes()`**

```swift
@Test("mapping event with custom body decodes correctly")
func customHandlerEventDecodes() throws {
    let yaml = """
    MyModel:
      model: readModel
      streams:
        - $ce-Order
      events:
        - OrderReassigned: |
            linkTo("Target-" + event.body.newId, event);
    """
    let decoder = YAMLDecoder()
    let definitions = try decoder.decode([String: EventProjectionDefinition].self, from: yaml)
    let def = try #require(definitions["MyModel"])
    #expect(def.kurrentDBEvents.count == 1)
    guard case .custom(let name, let body) = def.kurrentDBEvents[0] else {
        Issue.record("Expected .custom, got \(def.kurrentDBEvents[0])")
        return
    }
    #expect(name == "OrderReassigned")
    #expect(body.trimmingCharacters(in: .whitespacesAndNewlines) == #"linkTo("Target-" + event.body.newId, event);"#)
}
```

- [ ] **Step 3: Update `mixedEventListDecodes()`**

```swift
@Test("mixed event list decodes correctly")
func mixedEventListDecodes() throws {
    let yaml = """
    MyModel:
      model: readModel
      streams:
        - $ce-Order
      idField: orderId
      events:
        - OrderCreated
        - OrderReassigned: |
            linkTo("Target-" + event.body.newId, event);
    """
    let decoder = YAMLDecoder()
    let definitions = try decoder.decode([String: EventProjectionDefinition].self, from: yaml)
    let def = try #require(definitions["MyModel"])
    #expect(def.kurrentDBEvents.count == 2)
    guard case .plain(let firstName) = def.kurrentDBEvents[0] else {
        Issue.record("Expected first item to be .plain")
        return
    }
    #expect(firstName == "OrderCreated")
    guard case .custom(let secondName, _) = def.kurrentDBEvents[1] else {
        Issue.record("Expected second item to be .custom")
        return
    }
    #expect(secondName == "OrderReassigned")
}
```

- [ ] **Step 4: Update `eventsPropertyReturnsNames()`**

```swift
@Test("events computed property returns names for ProjectorGenerator compatibility")
func eventsPropertyReturnsNames() throws {
    let yaml = """
    MyModel:
      model: readModel
      streams:
        - $ce-Order
      idField: orderId
      events:
        - OrderCreated
        - OrderUpdated: |
            linkTo("T-" + event.body.x, event);
    """
    let decoder = YAMLDecoder()
    let definitions = try decoder.decode([String: EventProjectionDefinition].self, from: yaml)
    let def = try #require(definitions["MyModel"])
    #expect(def.events == ["OrderCreated", "OrderUpdated"])
}
```

- [ ] **Step 5: Rename `noCategory()` → `noStreams()` and update assertion**

```swift
@Test("definition without streams has nil streams")
func noStreams() throws {
    let yaml = """
    MyModel:
      model: readModel
      events:
        - OrderCreated
    """
    let decoder = YAMLDecoder()
    let definitions = try decoder.decode([String: EventProjectionDefinition].self, from: yaml)
    let def = try #require(definitions["MyModel"])
    #expect(def.streams == nil)
    #expect(def.idField == nil)
}
```

- [ ] **Step 6: Update `createdEventsMixedList()`**

```swift
@Test("createdEvents mixed list decodes correctly")
func createdEventsMixedList() throws {
    let yaml = """
    MyModel:
      model: readModel
      streams:
        - $ce-Order
      idField: orderId
      createdEvents:
        - OrderCreated
        - OrderImported: |
            linkTo("MyModel-" + event.body.importId, event);
    """
    let decoder = YAMLDecoder()
    let definitions = try decoder.decode([String: EventProjectionDefinition].self, from: yaml)
    let def = try #require(definitions["MyModel"])
    #expect(def.createdKurrentDBEvents.count == 2)
    guard case .plain = def.createdKurrentDBEvents[0] else {
        Issue.record("Expected first createdEvent to be .plain")
        return
    }
    guard case .custom = def.createdKurrentDBEvents[1] else {
        Issue.record("Expected second createdEvent to be .custom")
        return
    }
}
```

- [ ] **Step 7: Update `emptyCustomBodyThrows()`**

```swift
@Test("empty custom handler body throws emptyCustomHandlerBody error")
func emptyCustomBodyThrows() throws {
    let yaml = """
    MyModel:
      model: readModel
      streams:
        - $ce-Order
      events:
        - OrderReassigned: ""
    """
    let decoder = YAMLDecoder()
    #expect {
        _ = try decoder.decode([String: EventProjectionDefinition].self, from: yaml)
    } throws: { error in
        if error is KurrentDBProjectionError { return true }
        if case .dataCorrupted(let ctx) = error as? DecodingError,
           ctx.underlyingError is KurrentDBProjectionError { return true }
        return false
    }
}
```

- [ ] **Step 8: Update `plainEventWithoutIdFieldIsDecodable()`**

```swift
@Test("plain event without idField is decodable but generator throws missingIdField")
func plainEventWithoutIdFieldIsDecodable() throws {
    let yaml = """
    MyModel:
      model: readModel
      streams:
        - $ce-Order
      events:
        - OrderCreated
    """
    let decoder = YAMLDecoder()
    let definitions = try decoder.decode([String: EventProjectionDefinition].self, from: yaml)
    let def = try #require(definitions["MyModel"])
    #expect(def.kurrentDBEvents.count == 1)
    #expect(def.idField == nil)
}
```

### KurrentDBProjectionGeneratorTests.swift

- [ ] **Step 9: Update `noCategoryReturnsNil()` → `noStreamsReturnsNil()`**

```swift
@Test("definition without streams returns nil")
func noStreamsReturnsNil() throws {
    let definition = EventProjectionDefinition(
        model: .readModel,
        kurrentDBEvents: [.plain("OrderCreated")]
    )
    let generator = KurrentDBProjectionGenerator(name: "MyModel", definition: definition)
    let result = try generator.render()
    #expect(result == nil)
}
```

- [ ] **Step 10: Update `standardRoutingGeneratesJS()`**

```swift
@Test("standard routing generates correct fromStreams and linkTo")
func standardRoutingGeneratesJS() throws {
    let definition = EventProjectionDefinition(
        model: .readModel,
        streams: ["$ce-Quotation"],
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
```

- [ ] **Step 11: Update `customHandlerEmbeddedVerbatim()`**

```swift
@Test("custom handler body is embedded verbatim inside wrapper")
func customHandlerEmbeddedVerbatim() throws {
    let body = #"linkTo("OtherTarget-" + event.body.otherId, event);"#
    let definition = EventProjectionDefinition(
        model: .readModel,
        streams: ["$ce-Quotation"],
        kurrentDBEvents: [.custom(name: "QuotationReassigned", body: body)]
    )
    let generator = KurrentDBProjectionGenerator(name: "OC_GetQuotation", definition: definition)
    let js = try #require(try generator.render())
    #expect(js.contains("QuotationReassigned: function(state, event)"))
    #expect(js.contains(body))
}
```

- [ ] **Step 12: Update `mixedListGeneratesBoth()`**

```swift
@Test("mixed list generates both standard and custom handlers")
func mixedListGeneratesBoth() throws {
    let definition = EventProjectionDefinition(
        model: .readModel,
        streams: ["$ce-Order"],
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
```

- [ ] **Step 13: Update `plainEventWithoutIdFieldThrows()`**

```swift
@Test("plain event without idField throws missingIdFieldForPlainEvent")
func plainEventWithoutIdFieldThrows() throws {
    let definition = EventProjectionDefinition(
        model: .readModel,
        streams: ["$ce-Order"],
        kurrentDBEvents: [.plain("OrderCreated")]
    )
    let generator = KurrentDBProjectionGenerator(name: "MyModel", definition: definition)
    #expect(throws: KurrentDBProjectionError.missingIdFieldForPlainEvent(modelName: "MyModel", eventName: "OrderCreated")) {
        _ = try generator.render()
    }
}
```

- [ ] **Step 14: Update `createdEventsAppearFirst()`**

```swift
@Test("createdKurrentDBEvents appear before kurrentDBEvents in generated JS")
func createdEventsAppearFirst() throws {
    let definition = EventProjectionDefinition(
        model: .readModel,
        streams: ["$ce-Order"],
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
```

- [ ] **Step 15: Update `outputIncludesIsJsonGuard()`**

```swift
@Test("output includes isJson guard for every handler")
func outputIncludesIsJsonGuard() throws {
    let definition = EventProjectionDefinition(
        model: .readModel,
        streams: ["$ce-Order"],
        idField: "orderId",
        kurrentDBEvents: [.plain("OrderCreated")]
    )
    let generator = KurrentDBProjectionGenerator(name: "MyModel", definition: definition)
    let js = try #require(try generator.render())
    #expect(js.contains("event.isJson"))
}
```

- [ ] **Step 16: Update `outputContainsInitHandler()`**

```swift
@Test("output contains $init handler")
func outputContainsInitHandler() throws {
    let definition = EventProjectionDefinition(
        model: .readModel,
        streams: ["$ce-Order"],
        idField: "orderId",
        kurrentDBEvents: [.plain("OrderCreated")]
    )
    let generator = KurrentDBProjectionGenerator(name: "MyModel", definition: definition)
    let js = try #require(try generator.render())
    #expect(js.contains("$init: function()"))
}
```

### KurrentDBProjectionFileGeneratorTests (inside `KurrentDBProjectionGeneratorTests.swift`)

- [ ] **Step 17: Update `fileGeneratorWritesJsFile()`**

```swift
@Test("fileGeneratorWritesJsFile — writes correct JS file for definition with streams")
func fileGeneratorWritesJsFile() throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("KurrentDBProjectionFileGeneratorTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let yamlContent = """
    OC_GetOrder:
      model: readModel
      streams:
        - $ce-Order
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
```

- [ ] **Step 18: Update `fileGeneratorSkipsDefinitionsWithoutCategory()` → `fileGeneratorSkipsDefinitionsWithoutStreams()`**

```swift
@Test("fileGeneratorSkipsDefinitionsWithoutStreams — no JS file written when streams absent")
func fileGeneratorSkipsDefinitionsWithoutStreams() throws {
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
```

- [ ] **Step 19: Update `fileGeneratorCreatedEventsAppearFirst()`**

```swift
@Test("createdEvents appear before events in written JS file")
func fileGeneratorCreatedEventsAppearFirst() throws {
    let yaml = """
    OrderModel:
      model: readModel
      streams:
        - $ce-Order
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
```

- [ ] **Step 20: Update `fileGeneratorCreatesOutputDirectory()`**

```swift
@Test("fileGeneratorCreatesOutputDirectory — output directory is created when absent")
func fileGeneratorCreatesOutputDirectory() throws {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("KurrentDBProjectionFileGeneratorTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let yamlContent = """
    OrderModel:
      model: readModel
      streams:
        - $ce-Order
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
```

---

## Task 5: Run all tests and commit

- [ ] **Step 1: Run the KurrentDB test suites**

```bash
cd /Volumes/Development/swift-ddd-kit && swift test --filter KurrentDBProjection 2>&1
```

Expected: All tests pass. Zero failures.

- [ ] **Step 2: Run full test suite to catch regressions**

```bash
cd /Volumes/Development/swift-ddd-kit && swift test 2>&1 | tail -20
```

Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
cd /Volumes/Development/swift-ddd-kit && git add Sources/DomainEventGenerator/EventProjectionDefinition.swift Sources/DomainEventGenerator/Generator/Model/KurrentDBProjectionGenerator.swift Tests/DomainEventGeneratorTests/KurrentDBProjectionParsingTests.swift Tests/DomainEventGeneratorTests/KurrentDBProjectionGeneratorTests.swift
git commit -m "feat: replace category with streams in KurrentDB projection generator

Allow projections to listen to multiple full stream names directly
(e.g. \$ce-Order) instead of auto-prefixing a single category name."
```
