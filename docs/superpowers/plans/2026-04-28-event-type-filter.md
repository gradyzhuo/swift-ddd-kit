# EventTypeFilter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the spec at `docs/superpowers/specs/2026-04-28-event-type-filter-design.md` — `EventTypeFilter` protocol + generator-emitted concrete filters + runner integration, mirroring the existing `EventTypeMapper` pattern (composition + DI).

**Architecture:** New protocol in `EventSourcing` module. New `EventFilterGenerator` and `event-filter` CLI subcommand parallel to the existing event-mapper pipeline. New `generated-event-filter.swift` plugin output. Both `register` overloads on `PersistentSubscriptionRunner` accept an optional `eventFilter:` parameter (default `nil` = no filter, backwards-compatible).

**Tech Stack:** Swift 6, swift-kurrentdb 2.0.x, Swift Testing, swift-argument-parser, Yams.

**Spec reference:** `docs/superpowers/specs/2026-04-28-event-type-filter-design.md`

---

## File Structure

| Path | Action | Responsibility |
|---|---|---|
| `Sources/EventSourcing/Projector/EventTypeFilter.swift` | **NEW** | Protocol definition |
| `Sources/DomainEventGenerator/Generator/EventFilter/EventFilterGenerator.swift` | **NEW** | Code renderer (string-emitter) for one filter struct |
| `Sources/generate/EventFilter.swift` | **NEW** | CLI subcommand `event-filter` — invokes `EventFilterGenerator` per projection model, writes one output file |
| `Sources/generate/GenerateCommand.swift` | **MODIFY** | Register `GenerateEventFilterCommand` in subcommands list |
| `Plugins/ModelGeneratorPlugin/Plugin.swift` | **MODIFY** | Add 3rd `.buildCommand` invoking `generate event-filter` to produce `generated-event-filter.swift` |
| `Sources/KurrentSupport/Adapter/KurrentProjection.swift` | **MODIFY** | Both `register` overloads gain `eventFilter:` param; new `_shouldDispatchForTesting(eventType:filter:)` test hook |
| `Tests/EventSourcingTests/EventTypeFilterTests.swift` | **NEW** | Protocol unit tests (custom filter, default behavior) |
| `Tests/DomainEventGeneratorTests/EventFilterGeneratorTests.swift` | **NEW** | Generator output snapshot tests |
| `Tests/KurrentSupportUnitTests/KurrentProjectionRunnerFilterTests.swift` | **NEW** | Runner-level filter behavior unit tests via `_shouldDispatchForTesting` |
| `Tests/KurrentSupportIntegrationTests/KurrentProjectionRunnerIntegrationTests.swift` | **MODIFY** | End-to-end filter integration test (3 projectors, distinct event types) |
| `samples/KurrentProjectionDemo/...` | **NEW (revive)** | Cherry-pick `a74b76c` from `feature/kurrent-projection-runner-phase1`; add 3rd projector with `EventTypeFilter` |
| `README.md` | **MODIFY** | Add filter usage example to the Persistent Subscription Runner section |

---

## Pre-Flight

- [ ] **Verify branch + clean state**

```bash
git status
git branch --show-current   # expect: feature/event-type-filter
swift build 2>&1 | tail -3
```

Expected: clean state, on `feature/event-type-filter`, build succeeds.

- [ ] **Verify KurrentDB running** (for Task 8's integration test later)

```bash
docker ps --format '{{.Names}} {{.Image}}' | grep -i kurrent || echo "KurrentDB NOT running"
```

If not running, integration test in Task 8 will fail — surface this then.

---

## Task 1: `EventTypeFilter` protocol in EventSourcing

**Files:**
- Create: `Sources/EventSourcing/Projector/EventTypeFilter.swift`
- Create: `Tests/EventSourcingTests/EventTypeFilterTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/EventSourcingTests/EventTypeFilterTests.swift
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
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter EventTypeFilterTests 2>&1 | tail -10
```

Expected: FAIL — `cannot find 'EventTypeFilter'`.

- [ ] **Step 3: Implement the protocol**

```swift
// Sources/EventSourcing/Projector/EventTypeFilter.swift
//
// EventTypeFilter — pre-filter routing for projection runners.
// See spec: docs/superpowers/specs/2026-04-28-event-type-filter-design.md
//

/// A filter declaring which event types a projection (or arbitrary registration)
/// is interested in.
///
/// Pass an instance to `KurrentProjection.PersistentSubscriptionRunner.register(...)`
/// to short-circuit dispatch for unrelated event types — no `extractInput` call,
/// no storage fetch, no apply, no cursor advance.
///
/// Mirrors the `EventTypeMapper` pattern: protocol + concrete struct (often
/// generator-emitted) + DI parameter.
public protocol EventTypeFilter: Sendable {
    /// Returns `true` if the given event type should be processed by the
    /// associated projection; `false` to silently skip.
    func handles(eventType: String) -> Bool
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter EventTypeFilterTests 2>&1 | tail -10
```

Expected: PASS — all 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/EventSourcing/Projector/EventTypeFilter.swift Tests/EventSourcingTests/EventTypeFilterTests.swift
git commit -m "[ADD] EventTypeFilter protocol — DI-friendly event type pre-filter"
```

---

## Task 2: `EventFilterGenerator` code renderer

**Files:**
- Create: `Sources/DomainEventGenerator/Generator/EventFilter/EventFilterGenerator.swift`
- Create: `Tests/DomainEventGeneratorTests/EventFilterGeneratorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/DomainEventGeneratorTests/EventFilterGeneratorTests.swift
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
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter EventFilterGeneratorTests 2>&1 | tail -10
```

Expected: FAIL — `cannot find 'EventFilterGenerator'`.

- [ ] **Step 3: Implement the generator**

```swift
// Sources/DomainEventGenerator/Generator/EventFilter/EventFilterGenerator.swift
//
// EventFilterGenerator — renders a concrete `EventTypeFilter` struct
// for one projection model (modelName + the events it cares about).
// Output goes into `generated-event-filter.swift` (sibling to event mapper output).
//

import Foundation

package struct EventFilterGenerator {
    let modelName: String
    let eventNames: [String]

    package init(modelName: String, eventNames: [String]) {
        self.modelName = modelName
        self.eventNames = eventNames
    }

    package func render(accessLevel: AccessLevel) -> [String] {
        var lines: [String] = []

        lines.append("""
\(accessLevel.rawValue) struct \(modelName)EventFilter: EventTypeFilter {

    \(accessLevel.rawValue) init() {}

    \(accessLevel.rawValue) func handles(eventType: String) -> Bool {
        switch eventType {
""")

        if eventNames.isEmpty {
            // No cases — fall through to default.
        } else {
            let cases = eventNames.map { "\"\($0)\"" }.joined(separator: ", ")
            lines.append("""
        case \(cases):
            return true
""")
        }

        lines.append("""
        default:
            return false
        }
    }
}
""")
        return lines
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter EventFilterGeneratorTests 2>&1 | tail -10
```

Expected: PASS — all 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/DomainEventGenerator/Generator/EventFilter Tests/DomainEventGeneratorTests/EventFilterGeneratorTests.swift
git commit -m "[ADD] EventFilterGenerator — renders {ModelName}EventFilter struct"
```

---

## Task 3: `event-filter` CLI subcommand

**Files:**
- Create: `Sources/generate/EventFilter.swift`
- Modify: `Sources/generate/GenerateCommand.swift`

- [ ] **Step 1: Add the subcommand source file**

```swift
// Sources/generate/EventFilter.swift
//
// event-filter CLI subcommand — parallel to event-mapper.
// Generates `generated-event-filter.swift` containing one `*EventFilter` struct
// per projection model declared in projection-model.yaml.
//

import Yams
import Foundation
import ArgumentParser
import DomainEventGenerator

struct GenerateEventFilterCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "event-filter",
        abstract: "Generate event-filter swift files.")

    @Argument(help: "The path of the event file.", completion: .file(extensions: ["yaml", "yam"]))
    var eventDefinitionPath: String

    @Argument(help: "The path of the projection-model file.", completion: .file(extensions: ["yaml", "yam"]))
    var projectionModelDefinitionPath: String

    @Option(completion: .file(extensions: ["yaml", "yam"]), transform: {
        let url = URL(fileURLWithPath: $0)
        let yamlData = try Data(contentsOf: url)
        let yamlDecoder = YAMLDecoder()
        return try yamlDecoder.decode(GeneratorConfiguration.self, from: yamlData)
    })
    var configuration: GeneratorConfiguration

    @Option
    var inputType: InputType = .yaml

    @Option
    var defaultAggregateRootName: String

    @Option
    var accessModifier: AccessLevelArgument?

    @Option(name: .shortAndLong, help: "The path of the generated swift file")
    var output: String? = nil

    func run() throws {
        let projectorGenerator = try ProjectorGenerator(
            projectionModelYamlFileURL: .init(filePath: projectionModelDefinitionPath)
        )

        guard let outputPath = output else {
            throw GenerateCommand.Errors.outputPathMissing
        }

        let accessModifier = accessModifier?.value ?? configuration.accessModifier

        // EventTypeFilter lives in EventSourcing — that's the only required dep.
        let defaultDependencies = ["EventSourcing"]
        let configDependencies = configuration.dependencies ?? []
        let headerGenerator = HeaderGenerator(
            dependencies: defaultDependencies + configDependencies
        )

        var lines: [String] = []
        lines.append(contentsOf: headerGenerator.render())
        lines.append("")

        // One filter per projection model. Aggregate root is NOT included —
        // filters are read-side only.
        for (modelName, projectionModelDefinition) in projectorGenerator.definitions {
            var eventNames = projectionModelDefinition.events
            eventNames.append(contentsOf: projectionModelDefinition.createdEvents)
            if let deletedEvent = projectionModelDefinition.deletedEvent {
                eventNames.append(deletedEvent)
            }
            let filterGenerator = EventFilterGenerator(modelName: modelName, eventNames: eventNames)
            lines.append(contentsOf: filterGenerator.render(accessLevel: accessModifier))
            lines.append("")
        }

        let content = lines.joined(separator: "\n")
        try content.write(toFile: outputPath, atomically: true, encoding: .utf8)
    }
}
```

- [ ] **Step 2: Register the subcommand**

Edit `Sources/generate/GenerateCommand.swift`. Find:

```swift
subcommands: [
    GenerateEventCommand.self,
    GenerateEventMapperCommand.self,
    GenerateModelCommand.self,
    GenerateKurrentDBProjectionCommand.self
])
```

Add the new subcommand:

```swift
subcommands: [
    GenerateEventCommand.self,
    GenerateEventMapperCommand.self,
    GenerateEventFilterCommand.self,    // ← new
    GenerateModelCommand.self,
    GenerateKurrentDBProjectionCommand.self
])
```

- [ ] **Step 3: Verify build**

```bash
swift build 2>&1 | tail -5
```

Expected: clean build.

- [ ] **Step 4: Smoke-test the CLI**

Use one of the existing samples to run the new subcommand manually:

```bash
mkdir -p /tmp/eventfilter-smoke
swift run generate event-filter \
    --configuration samples/PostgresReadModelDemo/Sources/event-generator-config.yaml \
    --default-aggregate-root-name PostgresReadModelDemo \
    --output /tmp/eventfilter-smoke/generated-event-filter.swift \
    samples/PostgresReadModelDemo/Sources/event.yaml \
    samples/PostgresReadModelDemo/Sources/projection-model.yaml

cat /tmp/eventfilter-smoke/generated-event-filter.swift
```

Expected: file contains `internal struct OrderSummaryEventFilter: EventTypeFilter` with the 3 Order events listed.

- [ ] **Step 5: Commit**

```bash
git add Sources/generate/EventFilter.swift Sources/generate/GenerateCommand.swift
git commit -m "[ADD] generate event-filter CLI subcommand"
```

---

## Task 4: `ModelGeneratorPlugin` emits `generated-event-filter.swift`

**Files:**
- Modify: `Plugins/ModelGeneratorPlugin/Plugin.swift`

- [ ] **Step 1: Add the 3rd buildCommand**

Edit `Plugins/ModelGeneratorPlugin/Plugin.swift`. Find the existing `return [...]` block and add a 3rd entry:

```swift
//generated files target
let generatedProjectionHelperSource = generatedTargetDirectory.appending(path: "generated-projection-model.swift")
let generatedEventMapperSource = generatedTargetDirectory.appending(path: "generated-event-mapper.swift")
let generatedEventFilterSource = generatedTargetDirectory.appending(path: "generated-event-filter.swift")  // ← new

return [
    try .buildCommand(
        // (existing presenter command — unchanged)
    ),
    try .buildCommand(
        // (existing event-mapper command — unchanged)
    ),
    try .buildCommand(
        displayName: "EventFilter Generating...\(eventSource.url.path())",
        executable: tool("generate"),
        arguments: [
            "event-filter",
            "--configuration", configSource.url.path(),
            "--default-aggregate-root-name", targetName,
            "--output", generatedEventFilterSource.path(),
            eventSource.url.path(),
            projectionModelSource.url.path()
        ],
        inputFiles: [
            eventSource.url,
            projectionModelSource.url
        ],
        outputFiles: [
            generatedEventFilterSource
        ]
    )
]
```

- [ ] **Step 2: Verify the plugin emits the file**

```bash
cd samples/PostgresReadModelDemo
swift build 2>&1 | tail -5
find .build -name "generated-event-filter.swift" | head -3
```

Expected: build clean; the generated file appears in `.build/plugins/outputs/.../ModelGeneratorPlugin/generated/`.

- [ ] **Step 3: Inspect the generated file**

```bash
cat $(find .build -name "generated-event-filter.swift" | head -1)
```

Expected: file contains `internal struct OrderSummaryEventFilter: EventTypeFilter { ... }` with the Order events.

- [ ] **Step 4: Verify the existing sample still builds with the new generated file in scope**

```bash
swift build 2>&1 | tail -3
cd ../..
swift test --filter DomainEventGenerator 2>&1 | tail -10
```

Expected: clean build; existing tests still pass.

- [ ] **Step 5: Commit**

```bash
git add Plugins/ModelGeneratorPlugin/Plugin.swift
git commit -m "[ADD] ModelGeneratorPlugin: emit generated-event-filter.swift"
```

---

## Task 5: `register` low-level overload accepts `eventFilter:`

**Files:**
- Modify: `Sources/KurrentSupport/Adapter/KurrentProjection.swift`
- Create: `Tests/KurrentSupportUnitTests/KurrentProjectionRunnerFilterTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/KurrentSupportUnitTests/KurrentProjectionRunnerFilterTests.swift
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
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter KurrentProjectionRunnerFilterTests 2>&1 | tail -10
```

Expected: FAIL — `_shouldDispatchForTesting` not defined.

- [ ] **Step 3: Implement the test hook + update low-level register**

Edit `Sources/KurrentSupport/Adapter/KurrentProjection.swift`.

Add `import EventSourcing` at the top if not already present (it should be from Phase 1).

In `PersistentSubscriptionRunner` class body, add the test-only hook (next to `_registrationCountForTesting`):

```swift
        // Test-only — used by unit tests to verify filter integration.
        // Internal access; not part of the public API.
        internal static func _shouldDispatchForTesting(
            eventType: String,
            filter: (any EventTypeFilter)?
        ) -> Bool {
            guard let filter else { return true }
            return filter.handles(eventType: eventType)
        }
```

Update the low-level `register` to accept `eventFilter:` and use the helper:

```swift
        @discardableResult
        public func register<Input: Sendable>(
            eventFilter: (any EventTypeFilter)? = nil,
            extractInput: @Sendable @escaping (RecordedEvent) -> Input?,
            execute: @Sendable @escaping (Input) async throws -> Void
        ) -> Self {
            let registration = Registration(dispatch: { record in
                guard Self._shouldDispatchForTesting(
                    eventType: record.eventType, filter: eventFilter
                ) else { return }
                guard let input = extractInput(record) else { return }
                try await execute(input)
            })
            _registrations.withLock { $0.append(registration) }
            return self
        }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter KurrentProjectionRunnerFilterTests 2>&1 | tail -10
```

Expected: PASS — all 5 tests.

Also verify Phase 1 tests still pass:

```bash
swift test --filter KurrentProjectionRunnerSetupTests 2>&1 | tail -5
swift test --filter KurrentProjectionRetryPolicyTests 2>&1 | tail -5
```

Expected: still pass (no regression).

- [ ] **Step 5: Commit**

```bash
git add Sources/KurrentSupport/Adapter/KurrentProjection.swift Tests/KurrentSupportUnitTests/KurrentProjectionRunnerFilterTests.swift
git commit -m "[ADD] PersistentSubscriptionRunner: low-level register accepts eventFilter"
```

---

## Task 6: `register` high-level overload forwards `eventFilter:`

**Files:**
- Modify: `Sources/KurrentSupport/Adapter/KurrentProjection.swift`

- [ ] **Step 1: Update the high-level overload**

Edit `Sources/KurrentSupport/Adapter/KurrentProjection.swift`. Find the existing high-level `register(_:extractInput:)` overload and add `eventFilter:` parameter:

```swift
        @discardableResult
        public func register<Projector: EventSourcingProjector, Store: ReadModelStore>(
            _ stateful: StatefulEventSourcingProjector<Projector, Store>,
            eventFilter: (any EventTypeFilter)? = nil,
            extractInput: @Sendable @escaping (RecordedEvent) -> Projector.Input?
        ) -> Self
            where Store.Model == Projector.ReadModelType,
                  Projector.Input: Sendable,
                  Projector: Sendable
        {
            return register(eventFilter: eventFilter, extractInput: extractInput) { input in
                _ = try await stateful.execute(input: input)
            }
        }
```

- [ ] **Step 2: Verify build + Phase 1 tests still pass**

```bash
swift build 2>&1 | tail -3
swift test --filter KurrentProjectionRunnerSetupTests 2>&1 | tail -10
```

Expected: clean build; existing 4 setup tests still pass (existing call sites without `eventFilter` still compile via default).

- [ ] **Step 3: Commit**

```bash
git add Sources/KurrentSupport/Adapter/KurrentProjection.swift
git commit -m "[ADD] PersistentSubscriptionRunner: high-level register forwards eventFilter"
```

---

## Task 7: Integration test — end-to-end filter behavior

**Files:**
- Modify: `Tests/KurrentSupportIntegrationTests/KurrentProjectionRunnerIntegrationTests.swift`

- [ ] **Step 1: Append the new test suite**

Append to the existing integration test file:

```swift

@Suite("KurrentProjection.PersistentSubscriptionRunner — eventFilter integration", .serialized)
struct KurrentProjectionRunnerEventFilterTests {

    private struct OnlyEventA: EventTypeFilter {
        func handles(eventType: String) -> Bool { eventType == "EventA" }
    }
    private struct OnlyEventB: EventTypeFilter {
        func handles(eventType: String) -> Bool { eventType == "EventB" }
    }

    @Test("eventFilter pre-filters events by type — only matching projector fires")
    func filterRoutesToCorrectProjectorOnly() async throws {
        let client = KurrentDBClient.makeIntegrationTestClient()
        let groupName = "test-runner-filter-\(UUID().uuidString.prefix(8))"
        let category = "RunnerFilterTest\(UUID().uuidString.prefix(6))"
        let stream = "$ce-\(category)"

        try await client.persistentSubscriptions(stream: stream, group: groupName).create { options in
            options.settings.resolveLink = true
        }
        defer { Task { try? await client.persistentSubscriptions(stream: stream, group: groupName).delete() } }

        let aggregateStream = "\(category)-\(UUID().uuidString)"
        // Append two events of different types
        for eventType in ["EventA", "EventB"] {
            let payload = #"{}"#.data(using: .utf8)!
            let eventData = try EventData(eventType: eventType, payload: payload)
            _ = try await client.streams(of: .specified(aggregateStream))
                .append(events: eventData) { _ in }
        }

        let aCalls = LockedBox(0)
        let bCalls = LockedBox(0)

        let runner = KurrentProjection.PersistentSubscriptionRunner(
            client: client,
            stream: stream,
            groupName: groupName
        )
        .register(
            eventFilter: OnlyEventA(),
            extractInput: { _ -> Bool? in true },
            execute: { _ in aCalls.withLock { $0 += 1 } }
        )
        .register(
            eventFilter: OnlyEventB(),
            extractInput: { _ -> Bool? in true },
            execute: { _ in bCalls.withLock { $0 += 1 } }
        )

        let task = Task { try await runner.run() }

        // Poll up to 4 seconds for both projectors to receive their respective event.
        let deadline = Date().addingTimeInterval(4.0)
        while Date() < deadline {
            if aCalls.withLock({ $0 }) >= 1 && bCalls.withLock({ $0 }) >= 1 { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        task.cancel()
        _ = try? await task.value

        let a = aCalls.withLock { $0 }
        let b = bCalls.withLock { $0 }

        // Each projector saw exactly one event (its own type).
        // Without filter, both would have seen 2 events each.
        #expect(a == 1, "OnlyEventA registration was called \(a) times; expected exactly 1")
        #expect(b == 1, "OnlyEventB registration was called \(b) times; expected exactly 1")
    }
}
```

- [ ] **Step 2: Run the test**

```bash
swift test --filter KurrentProjectionRunnerEventFilterTests 2>&1 | tail -20
```

Expected: PASS — both counters at exactly 1.

- [ ] **Step 3: Verify all integration tests still pass**

```bash
swift test --filter KurrentSupportIntegrationTests 2>&1 | tail -15
```

Expected: all 6 suites pass (5 from Phase 1 + new filter suite).

- [ ] **Step 4: Commit**

```bash
git add Tests/KurrentSupportIntegrationTests/KurrentProjectionRunnerIntegrationTests.swift
git commit -m "[ADD] integration test: eventFilter pre-filters dispatch by event type"
```

---

## Task 8: Revive `KurrentProjectionDemo` sample + add filter usage

The sample was built but unmerged in the previous round (`a74b76c` on `feature/kurrent-projection-runner-phase1`). Cherry-pick it as a starting point, then add a 3rd projector with custom filter to demonstrate.

**Files:**
- Cherry-pick (or recreate): `samples/KurrentProjectionDemo/Package.swift`
- Cherry-pick (or recreate): `samples/KurrentProjectionDemo/Sources/event.yaml`
- Cherry-pick (or recreate): `samples/KurrentProjectionDemo/Sources/event-generator-config.yaml`
- Cherry-pick (or recreate): `samples/KurrentProjectionDemo/Sources/projection-model.yaml`
- Cherry-pick (or recreate): `samples/KurrentProjectionDemo/Sources/main.swift`

- [ ] **Step 1: Try to cherry-pick the existing sample commit**

```bash
git log --all --oneline | grep "KurrentProjectionDemo" | head -3
```

If `a74b76c` (or similar) appears:

```bash
git cherry-pick a74b76c
```

If the commit is gone (was on a deleted branch):

Check loose objects:
```bash
git fsck --lost-found 2>&1 | grep commit | head
```

If recoverable, cherry-pick the SHA. If not, recreate from spec — the spec includes the full main.swift skeleton.

- [ ] **Step 2: Verify the sample builds**

```bash
cd samples/KurrentProjectionDemo
swift build 2>&1 | tail -5
```

Expected: clean build; the new `generated-event-filter.swift` plugin output also appears in this sample's `.build/`.

- [ ] **Step 3: Add a 3rd projector with custom filter**

Modify `samples/KurrentProjectionDemo/Sources/main.swift`. Add a third read model that only cares about creation events:

```swift
// Add near the existing OrderSummary / OrderTimeline read models:

struct OrderRegistry: ReadModel, Codable, Sendable {
    let id: String
    var customerId: String = ""
    var createdAt: Date? = nil
}

struct OrderRegistryInput: CQRSProjectorInput, Sendable { let id: String }

// Add a third generator entry to projection-model.yaml:
// (see Step 4 — yaml change required first)
```

Update `samples/KurrentProjectionDemo/Sources/projection-model.yaml`:

```yaml
OrderSummary:
  model: readModel
  events:
    - OrderCreated
    - OrderAmountUpdated
    - OrderCancelled

OrderTimeline:
  model: readModel
  events:
    - OrderCreated
    - OrderAmountUpdated
    - OrderCancelled

OrderRegistry:
  model: readModel
  events:
    - OrderCreated
```

- [ ] **Step 4: Implement OrderRegistryProjector + use generated filter**

In `main.swift`:

```swift
struct OrderRegistryProjector: OrderRegistryProjectorProtocol, Sendable {
    typealias ReadModelType = OrderRegistry
    typealias Input = OrderRegistryInput
    typealias StorageCoordinator = KurrentStorageCoordinator<OrderRegistryProjector>

    static var categoryRule: StreamCategoryRule { .custom("Order") }
    let coordinator: KurrentStorageCoordinator<OrderRegistryProjector>

    func buildReadModel(input: Input) throws -> OrderRegistry? {
        OrderRegistry(id: input.id)
    }
    func when(readModel: inout OrderRegistry, event: OrderCreated) throws {
        readModel.customerId = event.customerId
        readModel.createdAt = event.occurred
    }
}

// In the runner setup, register with the generated filter:
.register(
    registryStateful,
    eventFilter: OrderRegistryEventFilter(),    // ← generated, only OrderCreated
    extractInput: { record in
        orderId(from: record).map(OrderRegistryInput.init)
    }
)
```

This demonstrates: when `OrderAmountUpdated` arrives, only `OrderSummary` and `OrderTimeline` projectors run; `OrderRegistry` is skipped at runner level (not just at apply switch).

- [ ] **Step 5: Run the sample, capture output**

```bash
cd samples/KurrentProjectionDemo
KURRENT_CLUSTER=true swift run KurrentProjectionDemo 2>&1 | tail -25
```

Expected output: Three read models populated (OrderSummary, OrderTimeline, OrderRegistry). OrderRegistry should only have `customerId` from the OrderCreated event — NOT from the OrderAmountUpdated events.

- [ ] **Step 6: Commit**

```bash
cd /Users/gradyzhuo/Dropbox/Work/OpenSource/swift-ddd-kit
git add samples/KurrentProjectionDemo/
git commit -m "[ADD] sample KurrentProjectionDemo + EventTypeFilter usage demo"
```

---

## Task 9: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Find the existing Persistent Subscription Runner section**

```bash
grep -n "Persistent Subscription Runner" README.md
```

- [ ] **Step 2: Add a sub-section about EventTypeFilter**

Insert after the existing Persistent Subscription Runner code example:

```markdown
#### EventTypeFilter — pre-filter routing (optional)

When you have multiple projectors registered to the same subscription but each
listens to a different subset of event types, attach an `EventTypeFilter` to
short-circuit dispatch for unrelated event types — no `extractInput`, no fetch,
no apply for events the projector doesn't care about.

```swift
runner
    .register(orderSummaryStateful,
              eventFilter: OrderSummaryEventFilter(),     // generated from yaml
              extractInput: { ... })
    .register(orderRegistryStateful,
              eventFilter: OrderRegistryEventFilter(),
              extractInput: { ... })
```

`{ModelName}EventFilter` structs are auto-generated by `ModelGeneratorPlugin`
based on the events listed in `projection-model.yaml`. You can also implement
`EventTypeFilter` yourself for custom rules:

```swift
struct OnlyTransientEvents: EventTypeFilter {
    func handles(eventType: String) -> Bool {
        eventType.hasPrefix("Transient")
    }
}
```

The `eventFilter` parameter is optional — omit it to dispatch every event
through `extractInput` (the Phase 1 default).
```

- [ ] **Step 3: Verify markdown renders**

```bash
grep -A 30 "EventTypeFilter — pre-filter" README.md
```

Expected: section is present and well-formatted.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "[DOC] README — EventTypeFilter usage"
```

---

## Final Verification

- [ ] **Step 1: Full test suite (skip Postgres if not running)**

```bash
swift test --filter "KurrentSupport|EventSourcing|DomainEventGenerator|ReadModelPersistence" 2>&1 | tail -10
```

Expected: all relevant tests pass. Postgres-dependent tests may be skipped if Postgres isn't running.

- [ ] **Step 2: Verify both samples still build**

```bash
cd samples/PostgresReadModelDemo && swift build 2>&1 | tail -3
cd ../KurrentProjectionDemo && swift build 2>&1 | tail -3
```

Both should build cleanly.

- [ ] **Step 3: Branch state check**

```bash
cd /Users/gradyzhuo/Dropbox/Work/OpenSource/swift-ddd-kit
git log --oneline main..HEAD
git status
```

Expected: a clean linear history of TDD commits, no uncommitted changes.

- [ ] **Step 4: Push and open PR (only after all tasks pass)**

```bash
git push -u origin feature/event-type-filter
gh pr create --title "Add EventTypeFilter — pre-filter routing for PersistentSubscriptionRunner" --body "$(cat <<'EOF'
## Summary

- New `EventTypeFilter` protocol in `EventSourcing` — DI-friendly, mirrors `EventTypeMapper` pattern
- `ModelGeneratorPlugin` emits `{ModelName}EventFilter` structs into `generated-event-filter.swift`
- Both `register` overloads on `PersistentSubscriptionRunner` accept optional `eventFilter:` parameter (default nil = no filter, backwards-compatible)
- Sample `KurrentProjectionDemo` revived and updated to demonstrate filter usage with 3 projectors

## Test plan

- [ ] `swift build` clean
- [ ] `swift test --filter EventTypeFilter` — protocol tests pass
- [ ] `swift test --filter EventFilterGeneratorTests` — generator tests pass
- [ ] `swift test --filter KurrentProjectionRunnerFilterTests` — runner-level filter unit tests pass
- [ ] `swift test --filter KurrentProjectionRunnerEventFilterTests` — integration test (requires KurrentDB) verifies pre-filtering works end-to-end
- [ ] No regression in Phase 1 tests (`KurrentProjectionRunnerSetup`, `KurrentProjectionRetryPolicy`, etc.)
- [ ] `samples/KurrentProjectionDemo` builds and runs, demonstrating 3-projector fan-out with filter
EOF
)"
```

---

## Phase Notes

This work refines Phase 1's runner without breaking it. Phase 2 (Postgres-shared transaction box, deferred) remains untouched. The composition + DI pattern established here generalizes to other future pluggable behaviors (custom retry policies, event reshape mappers, etc.).
