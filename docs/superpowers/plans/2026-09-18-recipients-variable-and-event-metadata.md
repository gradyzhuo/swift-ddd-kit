# Recipients-Resolving Variables & Event Metadata Access — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `variables.yaml` declare `type: recipients` variables (returning `[String]`, optionally
reading raw event metadata via `$event.metadata`), and let `notification.yaml`'s `recipients:` lists
reference them via `%recipients:X%` tokens alongside today's plain field names.

**Architecture:** Four additive, backward-compatible changes to the DomainEventGenerator's two
parsers and two code generators, plus one unrelated additive change to `ContextForwarder` so
metadata bytes actually reach the generated code. No existing `variables.yaml`/`notification.yaml`
file changes behavior — every new field/token is opt-in.

**Tech Stack:** Swift 6, Yams (YAML parsing), swift-testing (`@Test`/`@Suite`/`#expect`).

**Spec:** `docs/superpowers/specs/2026-09-18-recipients-variable-and-event-metadata-design.md` (NotificationContext repo — copy is not duplicated into this repo; read it there before starting).

## Global Constraints

- Every existing hand-constructed `ForwardedRecord(...)`, `VariableDefinition(...)`, and
  `NotificationEntry(...)` call site across the whole repo (production and test code) must keep
  compiling **unchanged** — all new fields/parameters are additive with defaults, and
  `NotificationEntry.recipients`'s element type change is bridged via `ExpressibleByStringLiteral`
  (Task 3) so existing `recipients: ["someField"]` array literals keep compiling and keep meaning
  exactly what they mean today.
- `$event.metadata`'s generated Swift type is always `Data`, generated property name always
  `eventMetadata`. Never user-specified.
- `type: recipients` variables are **never** routed through `VariablesProtocolGenerator`'s
  `__value(of:inputs:)` seam — that seam's `inputs: [String: String]` cannot carry a `Data` value,
  and widening it is explicitly out of scope (spec §3.2's correction). Recipients variables are
  called directly from `NotificationGenerator`'s generated `render()`.
- Strict separation: a `type: recipients` variable's placeholder must never resolve inside a text
  template, and a `type: environment` variable's name must never be targeted by `%recipients:X%`.
  Both directions are **generation-time errors**, not runtime.
- For every existing (token-free) `notification.yaml` entry, the generated `render()` code must be
  **byte-identical** to today's output — the new mixed-recipients code path only activates when a
  `%recipients:X%` token is actually present in that entry's `recipients:` list. This keeps every
  existing golden-output-style assertion (e.g. `NotificationGeneratorTests.rendersRecipients`)
  passing unmodified.
- Cross-validation against `variables.yaml` (does `X` exist, is it the right `type`) happens at
  **generation time** (`NotificationGenerator`), never at `notification.yaml` parse time — the
  parser has no access to the variables list, exactly as today's placeholder cross-validation works.

---

### Task 1: `ForwardedRecord` carries `customMetadata`

**Files:**
- Modify: `Sources/ContextForwarder/ForwardedRecord.swift`
- Modify: `Sources/ContextForwarder/ContextForwarder.swift:256-263` (`init(from event:)`)
- Test: `Tests/ContextForwarderTests/ForwardedRecordTests.swift`

**Interfaces:**
- Produces: `ForwardedRecord.customMetadata: Data` (default `Data()`), consumed by nothing yet in
  this repo — OC will read it directly once it adopts `$event.metadata` (out of scope here, per
  spec §6.3).

- [ ] **Step 1: Write the failing test**

Add to `Tests/ContextForwarderTests/ForwardedRecordTests.swift`:

```swift
    @Test("customMetadata defaults to empty Data when not provided")
    func customMetadataDefaultsToEmpty() {
        let record = ForwardedRecord(
            eventType: "X", streamName: "s", eventId: "e",
            data: #"{"who":"acc-1"}"#.data(using: .utf8)!)
        #expect(record.customMetadata == Data())
    }

    @Test("customMetadata round-trips when explicitly provided")
    func customMetadataRoundTrips() {
        let metadata = #"{"operatorId":"op-1"}"#.data(using: .utf8)!
        let record = ForwardedRecord(
            eventType: "X", streamName: "s", eventId: "e",
            data: #"{"who":"acc-1"}"#.data(using: .utf8)!,
            customMetadata: metadata)
        #expect(record.customMetadata == metadata)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ForwardedRecordTests`
Expected: FAIL — `value of type 'ForwardedRecord' has no member 'customMetadata'` (and the
`customMetadata:` label doesn't exist on `init` yet).

- [ ] **Step 3: Add `customMetadata` to `ForwardedRecord`**

In `Sources/ContextForwarder/ForwardedRecord.swift`, change:

```swift
public struct ForwardedRecord: Sendable {
    public let eventType: String
    public let streamName: String
    public let eventId: String
    public let data: Data

    public init(eventType: String, streamName: String, eventId: String, data: Data) {
        self.eventType = eventType
        self.streamName = streamName
        self.eventId = eventId
        self.data = data
    }
```

to:

```swift
public struct ForwardedRecord: Sendable {
    public let eventType: String
    public let streamName: String
    public let eventId: String
    public let data: Data
    /// Raw KurrentDB `customMetadata` bytes for this event — schema-agnostic (each context
    /// defines its own metadata shape and decodes this itself; see e.g. `$event.metadata` in
    /// swift-ddd-kit's notification-definition variables framework). Empty `Data()` when the
    /// source event carried none, or for a hand-constructed record that doesn't set it.
    public let customMetadata: Data

    public init(
        eventType: String, streamName: String, eventId: String, data: Data,
        customMetadata: Data = Data()
    ) {
        self.eventType = eventType
        self.streamName = streamName
        self.eventId = eventId
        self.data = data
        self.customMetadata = customMetadata
    }
```

- [ ] **Step 4: Pass `customMetadata` through in `init(from event:)`**

In `Sources/ContextForwarder/ContextForwarder.swift`, change (lines 256-263):

```swift
    init(from event: ReadEvent) {
        let record = event.record
        self.init(
            eventType: record.eventType,
            streamName: record.streamIdentifier.name,
            eventId: record.id.uuidString,
            data: record.data)
    }
```

to:

```swift
    init(from event: ReadEvent) {
        let record = event.record
        self.init(
            eventType: record.eventType,
            streamName: record.streamIdentifier.name,
            eventId: record.id.uuidString,
            data: record.data,
            customMetadata: record.customMetadata)
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ForwardedRecordTests`
Expected: PASS (4 tests: the 2 pre-existing plus the 2 new ones).

- [ ] **Step 6: Run the full ContextForwarder test target to confirm no regressions**

Run: `swift test --filter ContextForwarderTests`
Expected: PASS, same count as before this task plus 2.

- [ ] **Step 7: Commit**

```bash
git add Sources/ContextForwarder/ForwardedRecord.swift Sources/ContextForwarder/ContextForwarder.swift Tests/ContextForwarderTests/ForwardedRecordTests.swift
git commit -m "feat: ForwardedRecord carries KurrentDB customMetadata"
```

---

### Task 2: `variables.yaml` — `type:` and the `$event.metadata` reserved input

**Files:**
- Modify: `Sources/DomainEventGenerator/Generator/Notification/VariablesDefinition.swift`
- Modify: `Sources/DomainEventGenerator/Generator/Notification/VariablesProtocolGenerator.swift`
- Test: `Tests/DomainEventGeneratorTests/VariablesParsingTests.swift`
- Test: `Tests/DomainEventGeneratorTests/VariablesProtocolGeneratorTests.swift`

**Interfaces:**
- Produces: `VariableType` enum (`.environment` / `.recipients`); `VariableDefinition.type:
  VariableType` (defaults `.environment` in `init`, so every existing `VariableDefinition(name:
  placeholder: inputs:)` call site keeps compiling); a `type: recipients` variable's protocol
  method returns `[String]` instead of `String`; `$event.metadata` parses to the input tuple
  `(name: "eventMetadata", type: "Data")` — Task 4 reads this tuple exactly like any other input.
- Consumes: nothing from Task 1 or Task 3 — independent of both at compile time.

- [ ] **Step 1: Write failing parser tests**

Add to `Tests/DomainEventGeneratorTests/VariablesParsingTests.swift`:

```swift
    @Test("type is optional and defaults to environment")
    func typeDefaultsToEnvironment() throws {
        let yaml = """
        QuotingCaseGroupName:
          placeholder: QuotingCaseGroupName
          inputs:
            - quotingCaseGroupingId: String
        """
        let variables = try VariablesParser.parse(yaml: yaml)
        #expect(variables[0].type == .environment)
    }

    @Test("type: recipients parses")
    func typeRecipientsParses() throws {
        let yaml = """
        AssignedDepartmentMembers:
          type: recipients
          placeholder: AssignedDepartmentMembers
          inputs:
            - quotingCaseGroupingId: String
        """
        let variables = try VariablesParser.parse(yaml: yaml)
        #expect(variables[0].type == .recipients)
    }

    @Test("unknown type value throws invalidType")
    func unknownTypeThrows() {
        let yaml = """
        SomeVariable:
          type: bogus
          placeholder: SomeVariable
        """
        #expect(throws: VariablesParseError.invalidType(variable: "SomeVariable", type: "bogus")) {
            _ = try VariablesParser.parse(yaml: yaml)
        }
    }

    @Test("$event.metadata parses as a bare reserved input with type Data")
    func eventMetadataParses() throws {
        let yaml = """
        AssignedDepartmentMembers:
          type: recipients
          placeholder: AssignedDepartmentMembers
          inputs:
            - quotingCaseGroupingId: String
            - $event.metadata
        """
        let variables = try VariablesParser.parse(yaml: yaml)
        #expect(variables[0].inputs.count == 2)
        #expect(variables[0].inputs[0].name == "quotingCaseGroupingId")
        #expect(variables[0].inputs[0].type == "String")
        #expect(variables[0].inputs[1].name == "eventMetadata")
        #expect(variables[0].inputs[1].type == "Data")
    }

    @Test("$event.metadata on a type: environment variable throws metadataOnNonRecipientsVariable")
    func eventMetadataOnEnvironmentThrows() {
        let yaml = """
        QuotingCaseGroupName:
          placeholder: QuotingCaseGroupName
          inputs:
            - quotingCaseGroupingId: String
            - $event.metadata
        """
        #expect(throws: VariablesParseError.metadataOnNonRecipientsVariable(variable: "QuotingCaseGroupName")) {
            _ = try VariablesParser.parse(yaml: yaml)
        }
    }

    @Test("$event.metadata with an explicit type suffix throws explicitMetadataType")
    func eventMetadataExplicitTypeThrows() {
        let yaml = """
        AssignedDepartmentMembers:
          type: recipients
          placeholder: AssignedDepartmentMembers
          inputs:
            - $event.metadata: Data
        """
        #expect(throws: VariablesParseError.explicitMetadataType(variable: "AssignedDepartmentMembers")) {
            _ = try VariablesParser.parse(yaml: yaml)
        }
    }

    @Test("a bare scalar input other than $event.metadata is still malformedInput")
    func otherBareScalarStillMalformed() {
        let yaml = """
        SomeVariable:
          placeholder: SomeVariable
          inputs:
            - justAName
        """
        #expect(throws: VariablesParseError.malformedInput(variable: "SomeVariable")) {
            _ = try VariablesParser.parse(yaml: yaml)
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter VariablesParsingTests`
Expected: FAIL to compile — `VariableType`, `.type`, `VariablesParseError.invalidType` etc. don't
exist yet.

- [ ] **Step 3: Add `VariableType` and `type` to `VariableDefinition`**

In `Sources/DomainEventGenerator/Generator/Notification/VariablesDefinition.swift`, change:

```swift
/// One declared template variable: its generated method name, the `%placeholder%` token it
/// resolves, and its ordered, single-key `inputs` list (method parameter order).
package struct VariableDefinition: Equatable {
    package let name: String
    package let placeholder: String
    package let inputs: [(name: String, type: String)]

    package init(name: String, placeholder: String, inputs: [(name: String, type: String)]) {
        self.name = name
        self.placeholder = placeholder
        self.inputs = inputs
    }

    package static func == (lhs: VariableDefinition, rhs: VariableDefinition) -> Bool {
        lhs.name == rhs.name
            && lhs.placeholder == rhs.placeholder
            && lhs.inputs.count == rhs.inputs.count
            && zip(lhs.inputs, rhs.inputs).allSatisfy { $0.name == $1.name && $0.type == $1.type }
    }
}
```

to:

```swift
/// Whether a variable resolves ordinary template text (`environment`, the default) or a
/// notification entry's recipient list (`recipients`, returns `[String]`). See spec:
/// docs/superpowers/specs/2026-09-18-recipients-variable-and-event-metadata-design.md §3.1
package enum VariableType: String, Equatable, Sendable {
    case environment
    case recipients
}

/// One declared template variable: its generated method name, the `%placeholder%` token it
/// resolves, its type (§3.1), and its ordered, single-key `inputs` list (method parameter order).
package struct VariableDefinition: Equatable {
    package let name: String
    package let placeholder: String
    package let type: VariableType
    package let inputs: [(name: String, type: String)]

    package init(
        name: String, placeholder: String, type: VariableType = .environment,
        inputs: [(name: String, type: String)]
    ) {
        self.name = name
        self.placeholder = placeholder
        self.type = type
        self.inputs = inputs
    }

    package static func == (lhs: VariableDefinition, rhs: VariableDefinition) -> Bool {
        lhs.name == rhs.name
            && lhs.placeholder == rhs.placeholder
            && lhs.type == rhs.type
            && lhs.inputs.count == rhs.inputs.count
            && zip(lhs.inputs, rhs.inputs).allSatisfy { $0.name == $1.name && $0.type == $1.type }
    }
}
```

- [ ] **Step 4: Add the new parse errors**

In the same file, change:

```swift
package enum VariablesParseError: Error, Equatable, Sendable {
    case missingPlaceholder(variable: String)
    case duplicatePlaceholder(placeholder: String)
    case malformedInput(variable: String)
    case unsupportedInputType(variable: String, input: String, type: String)
}

extension VariablesParseError: CustomStringConvertible {
    package var description: String {
        switch self {
        case .missingPlaceholder(let variable):
            return "variable '\(variable)': missing required `placeholder` key"
        case .duplicatePlaceholder(let placeholder):
            return "placeholder '\(placeholder)' is declared by more than one variable"
        case .malformedInput(let variable):
            return "variable '\(variable)': malformed `inputs` entry (expected an ordered list of single-key `name: SwiftType` maps)"
        case .unsupportedInputType(let variable, let input, let type):
            return "variable '\(variable)': input '\(input)' has unsupported type '\(type)' (only 'String' is supported)"
        }
    }
}
```

to:

```swift
package enum VariablesParseError: Error, Equatable, Sendable {
    case missingPlaceholder(variable: String)
    case duplicatePlaceholder(placeholder: String)
    case malformedInput(variable: String)
    case unsupportedInputType(variable: String, input: String, type: String)
    case invalidType(variable: String, type: String)
    case metadataOnNonRecipientsVariable(variable: String)
    case explicitMetadataType(variable: String)
}

extension VariablesParseError: CustomStringConvertible {
    package var description: String {
        switch self {
        case .missingPlaceholder(let variable):
            return "variable '\(variable)': missing required `placeholder` key"
        case .duplicatePlaceholder(let placeholder):
            return "placeholder '\(placeholder)' is declared by more than one variable"
        case .malformedInput(let variable):
            return "variable '\(variable)': malformed `inputs` entry (expected an ordered list of single-key `name: SwiftType` maps)"
        case .unsupportedInputType(let variable, let input, let type):
            return "variable '\(variable)': input '\(input)' has unsupported type '\(type)' (only 'String' is supported)"
        case .invalidType(let variable, let type):
            return "variable '\(variable)': unknown `type` value '\(type)' (expected 'environment' or 'recipients')"
        case .metadataOnNonRecipientsVariable(let variable):
            return "variable '\(variable)': `$event.metadata` is only usable on `type: recipients` variables"
        case .explicitMetadataType(let variable):
            return "variable '\(variable)': `$event.metadata` must not have an explicit `: Type` suffix (its type is always Data)"
        }
    }
}
```

- [ ] **Step 5: Parse `type:` and `$event.metadata` in `VariablesParser.parse`**

In the same file, change:

```swift
        for (keyNode, valueNode) in mapping {
            let variableName = keyNode.string ?? ""

            guard let variableMapping = valueNode.mapping,
                  let placeholder = variableMapping["placeholder"]?.string else {
                throw VariablesParseError.missingPlaceholder(variable: variableName)
            }

            guard seenPlaceholders.insert(placeholder).inserted else {
                throw VariablesParseError.duplicatePlaceholder(placeholder: placeholder)
            }

            try IdentifierValidation.validateLowerCamel(variableName, kind: .variableName)

            var inputs: [(name: String, type: String)] = []
            if let inputsSequence = variableMapping["inputs"]?.sequence {
                for inputItem in inputsSequence {
                    guard let inputMapping = inputItem.mapping, inputMapping.count == 1,
                          let pair = inputMapping.first else {
                        throw VariablesParseError.malformedInput(variable: variableName)
                    }
                    let inputName = pair.key.string ?? ""
                    let inputType = pair.value.string ?? ""
                    guard inputType == "String" else {
                        throw VariablesParseError.unsupportedInputType(
                            variable: variableName, input: inputName, type: inputType)
                    }
                    try IdentifierValidation.validate(inputName, kind: .inputName)
                    inputs.append((name: inputName, type: inputType))
                }
            }

            variables.append(VariableDefinition(name: variableName, placeholder: placeholder, inputs: inputs))
        }
```

to:

```swift
        for (keyNode, valueNode) in mapping {
            let variableName = keyNode.string ?? ""

            guard let variableMapping = valueNode.mapping,
                  let placeholder = variableMapping["placeholder"]?.string else {
                throw VariablesParseError.missingPlaceholder(variable: variableName)
            }

            guard seenPlaceholders.insert(placeholder).inserted else {
                throw VariablesParseError.duplicatePlaceholder(placeholder: placeholder)
            }

            try IdentifierValidation.validateLowerCamel(variableName, kind: .variableName)

            let type: VariableType
            if let typeValue = variableMapping["type"]?.string {
                guard let parsedType = VariableType(rawValue: typeValue) else {
                    throw VariablesParseError.invalidType(variable: variableName, type: typeValue)
                }
                type = parsedType
            } else {
                type = .environment
            }

            var inputs: [(name: String, type: String)] = []
            if let inputsSequence = variableMapping["inputs"]?.sequence {
                for inputItem in inputsSequence {
                    // `$event.metadata` is the one `inputs:` entry allowed to be a bare scalar
                    // (no `mapping`) rather than a single-key `name: Type` map.
                    if inputItem.mapping == nil, let scalar = inputItem.string {
                        guard scalar == "$event.metadata" else {
                            throw VariablesParseError.malformedInput(variable: variableName)
                        }
                        guard type == .recipients else {
                            throw VariablesParseError.metadataOnNonRecipientsVariable(variable: variableName)
                        }
                        inputs.append((name: "eventMetadata", type: "Data"))
                        continue
                    }

                    guard let inputMapping = inputItem.mapping, inputMapping.count == 1,
                          let pair = inputMapping.first else {
                        throw VariablesParseError.malformedInput(variable: variableName)
                    }
                    let inputName = pair.key.string ?? ""
                    let inputType = pair.value.string ?? ""
                    guard inputName != "$event.metadata" else {
                        throw VariablesParseError.explicitMetadataType(variable: variableName)
                    }
                    guard inputType == "String" else {
                        throw VariablesParseError.unsupportedInputType(
                            variable: variableName, input: inputName, type: inputType)
                    }
                    try IdentifierValidation.validate(inputName, kind: .inputName)
                    inputs.append((name: inputName, type: inputType))
                }
            }

            variables.append(VariableDefinition(name: variableName, placeholder: placeholder, type: type, inputs: inputs))
        }
```

- [ ] **Step 6: Run parser tests to verify they pass**

Run: `swift test --filter VariablesParsingTests`
Expected: PASS (all pre-existing tests plus the 7 new ones).

- [ ] **Step 7: Write failing generator tests**

Add to `Tests/DomainEventGeneratorTests/VariablesProtocolGeneratorTests.swift`:

```swift
    @Test("type: recipients variable generates a protocol method returning [String]")
    func recipientsVariableReturnsStringArray() {
        let variables = [
            VariableDefinition(
                name: "AssignedDepartmentMembers", placeholder: "AssignedDepartmentMembers",
                type: .recipients,
                inputs: [(name: "quotingCaseGroupingId", type: "String"), (name: "eventMetadata", type: "Data")]
            ),
        ]
        let generator = VariablesProtocolGenerator(protocolName: "OpportunityNotificationVariables", variables: variables)
        let output = generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(output.contains(
            "func assignedDepartmentMembers(quotingCaseGroupingId: String, eventMetadata: Data) async throws -> [String]"))
    }

    @Test("type: recipients variables are excluded from the __value dispatch seam")
    func recipientsVariableExcludedFromSeam() {
        let variables = [
            VariableDefinition(
                name: "AssignedDepartmentMembers", placeholder: "AssignedDepartmentMembers",
                type: .recipients,
                inputs: [(name: "quotingCaseGroupingId", type: "String")]
            ),
            VariableDefinition(
                name: "QuotingCaseGroupName", placeholder: "QuotingCaseGroupName",
                inputs: [(name: "quotingCaseGroupingId", type: "String")]
            ),
        ]
        let generator = VariablesProtocolGenerator(protocolName: "OpportunityNotificationVariables", variables: variables)
        let output = generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(output.contains("case \"QuotingCaseGroupName\":"))
        #expect(!output.contains("case \"AssignedDepartmentMembers\":"))
        #expect(!output.contains("self.assignedDepartmentMembers"))
    }
```

- [ ] **Step 8: Run generator tests to verify they fail**

Run: `swift test --filter VariablesProtocolGeneratorTests`
Expected: FAIL — protocol method still declares `-> String` for every variable, and the switch
still emits a `case "AssignedDepartmentMembers":` branch.

- [ ] **Step 9: Update `VariablesProtocolGenerator.render`**

In `Sources/DomainEventGenerator/Generator/Notification/VariablesProtocolGenerator.swift`, change:

```swift
        // 1. The protocol.
        var protocolLines = ["\(access) protocol \(protocolName): Sendable {"]
        for variable in sortedVariables {
            protocolLines.append("    func \(Self.lowerCamel(variable.name))(\(Self.parameterList(variable.inputs))) async throws -> String")
        }
        protocolLines.append("}")
        lines.append(protocolLines.joined(separator: "\n"))
```

to:

```swift
        // 1. The protocol.
        var protocolLines = ["\(access) protocol \(protocolName): Sendable {"]
        for variable in sortedVariables {
            let returnType = variable.type == .recipients ? "[String]" : "String"
            protocolLines.append("    func \(Self.lowerCamel(variable.name))(\(Self.parameterList(variable.inputs))) async throws -> \(returnType)")
        }
        protocolLines.append("}")
        lines.append(protocolLines.joined(separator: "\n"))
```

and change:

```swift
        var seamLines = ["extension \(protocolName) {"]
        seamLines.append("    \(access) func __value(of placeholder: String, inputs: [String: String]) async throws -> String {")
        seamLines.append("        switch placeholder {")
        for variable in sortedVariables {
```

to:

```swift
        // `type: recipients` variables never resolve through this string-keyed seam — they're
        // called directly from NotificationGenerator's render() (§3.2's correction) — and their
        // inputs may include a non-String `eventMetadata: Data`, which this seam's
        // `[String: String]` cannot carry anyway.
        let seamVariables = sortedVariables.filter { $0.type == .environment }
        var seamLines = ["extension \(protocolName) {"]
        seamLines.append("    \(access) func __value(of placeholder: String, inputs: [String: String]) async throws -> String {")
        seamLines.append("        switch placeholder {")
        for variable in seamVariables {
```

- [ ] **Step 10: Run generator tests to verify they pass**

Run: `swift test --filter VariablesProtocolGeneratorTests`
Expected: PASS (all pre-existing tests plus the 2 new ones).

- [ ] **Step 11: Run the full DomainEventGenerator test target to confirm no regressions**

Run: `swift test --filter DomainEventGeneratorTests`
Expected: PASS.

- [ ] **Step 12: Commit**

```bash
git add Sources/DomainEventGenerator/Generator/Notification/VariablesDefinition.swift Sources/DomainEventGenerator/Generator/Notification/VariablesProtocolGenerator.swift Tests/DomainEventGeneratorTests/VariablesParsingTests.swift Tests/DomainEventGeneratorTests/VariablesProtocolGeneratorTests.swift
git commit -m "feat: variables.yaml type: recipients and \$event.metadata"
```

---

### Task 3: `notification.yaml` — parse `%recipients:X%` tokens

**Files:**
- Modify: `Sources/DomainEventGenerator/Generator/Notification/NotificationDefinitionFile.swift`
- Test: `Tests/DomainEventGeneratorTests/NotificationParsingTests.swift`

**Interfaces:**
- Produces: `RecipientSource` enum (`.field(String)` / `.variable(String)`), conforming to
  `ExpressibleByStringLiteral` so `NotificationEntry.recipients: [RecipientSource]` accepts today's
  plain `["someField"]` literals unchanged everywhere in the repo (production code and tests
  outside this task). `NotificationEntry.recipients` changes from `[String]` to `[RecipientSource]`.
- Consumes: nothing from Task 2 — a `%recipients:X%` token's `X` is stored as a bare string here;
  whether `X` actually exists in `variables.yaml` and is `type: recipients` is validated in Task 4.

- [ ] **Step 1: Write failing tests**

Add to `Tests/DomainEventGeneratorTests/NotificationParsingTests.swift`:

```swift
    @Test("a %recipients:X% token parses as RecipientSource.variable")
    func recipientsTokenParsesAsVariable() throws {
        let yaml = """
        AssignedMemberAdded:
          notifications:
            - type: mail
              recipients:
                - %recipients:AssignedDepartmentMembers%
              subject: hi
              content: hi
        """
        let definitions = try NotificationDefinitionParser.parse(yaml: yaml)
        let entry = try #require(definitions.first?.notifications.first)
        #expect(entry.recipients == [.variable("AssignedDepartmentMembers")])
    }

    @Test("a plain identifier still parses as RecipientSource.field")
    func plainIdentifierParsesAsField() throws {
        let yaml = """
        AssignedMemberAdded:
          notifications:
            - type: mail
              recipients:
                - memberIds
              subject: hi
              content: hi
        """
        let definitions = try NotificationDefinitionParser.parse(yaml: yaml)
        let entry = try #require(definitions.first?.notifications.first)
        #expect(entry.recipients == [.field("memberIds")])
    }

    @Test("a recipients list mixing a plain identifier and a %recipients:X% token parses both, in order")
    func mixedRecipientsListParsesBoth() throws {
        let yaml = """
        AssignedMemberAdded:
          notifications:
            - type: mail
              recipients:
                - memberIds
                - %recipients:AssignedDepartmentMembers%
              subject: hi
              content: hi
        """
        let definitions = try NotificationDefinitionParser.parse(yaml: yaml)
        let entry = try #require(definitions.first?.notifications.first)
        #expect(entry.recipients == [.field("memberIds"), .variable("AssignedDepartmentMembers")])
    }

    @Test("an ill-formed %recipients: token falls through to plain identifier validation and throws")
    func illFormedTokenFallsThroughToIdentifierValidation() {
        let yaml = """
        AssignedMemberAdded:
          notifications:
            - type: mail
              recipients:
                - %recipients:%
              subject: hi
              content: hi
        """
        #expect(throws: IdentifierValidationError.self) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter NotificationParsingTests`
Expected: FAIL to compile — `RecipientSource` doesn't exist yet, and `entry.recipients ==
[.variable(...)]` doesn't type-check against `[String]`.

- [ ] **Step 3: Add `RecipientSource` and change `NotificationEntry.recipients`'s type**

In `Sources/DomainEventGenerator/Generator/Notification/NotificationDefinitionFile.swift`, change:

```swift
/// One channel entry (`mail`/`inApp`) for a single event, with its fields in the type's
/// canonical schema order (`mail`: subject, content; `inApp`: title, content).
package struct NotificationEntry: Equatable {
    package let type: String
    package let render: NotificationRenderFormat
    package let recipients: [String]
    package let fields: [(name: String, template: String)]

    package init(
        type: String, render: NotificationRenderFormat, recipients: [String],
        fields: [(name: String, template: String)]
    ) {
        self.type = type
        self.render = render
        self.recipients = recipients
        self.fields = fields
    }

    package static func == (lhs: NotificationEntry, rhs: NotificationEntry) -> Bool {
        lhs.type == rhs.type
            && lhs.render == rhs.render
            && lhs.recipients == rhs.recipients
            && lhs.fields.count == rhs.fields.count
            && zip(lhs.fields, rhs.fields).allSatisfy { $0.name == $1.name && $0.template == $1.template }
    }
}
```

to:

```swift
/// A single `recipients:` list entry — either a plain event-field name (unchanged, `.field`) or a
/// `%recipients:X%` token naming a `type: recipients` variable in `variables.yaml` (`.variable`,
/// resolved and validated at generation time — see NotificationGenerator). Conforms to
/// `ExpressibleByStringLiteral` so every existing `recipients: ["someField"]` array literal in
/// this repo keeps compiling unchanged, producing `.field("someField")` exactly as before.
package enum RecipientSource: Equatable, Sendable, ExpressibleByStringLiteral {
    case field(String)
    case variable(String)

    package init(stringLiteral value: String) {
        self = .field(value)
    }
}

/// One channel entry (`mail`/`inApp`) for a single event, with its fields in the type's
/// canonical schema order (`mail`: subject, content; `inApp`: title, content).
package struct NotificationEntry: Equatable {
    package let type: String
    package let render: NotificationRenderFormat
    package let recipients: [RecipientSource]
    package let fields: [(name: String, template: String)]

    package init(
        type: String, render: NotificationRenderFormat, recipients: [RecipientSource],
        fields: [(name: String, template: String)]
    ) {
        self.type = type
        self.render = render
        self.recipients = recipients
        self.fields = fields
    }

    package static func == (lhs: NotificationEntry, rhs: NotificationEntry) -> Bool {
        lhs.type == rhs.type
            && lhs.render == rhs.render
            && lhs.recipients == rhs.recipients
            && lhs.fields.count == rhs.fields.count
            && zip(lhs.fields, rhs.fields).allSatisfy { $0.name == $1.name && $0.template == $1.template }
    }
}
```

- [ ] **Step 4: Recognize `%recipients:X%` tokens in the parser**

In the same file, change:

```swift
package enum NotificationDefinitionParser {

    /// Closed field schema per notification type, in canonical (generated-field) order.
    private static let typeSchemas: [String: [String]] = [
        "mail": ["subject", "content"],
        "inApp": ["title", "content"],
    ]
```

to:

```swift
package enum NotificationDefinitionParser {

    /// Closed field schema per notification type, in canonical (generated-field) order.
    private static let typeSchemas: [String: [String]] = [
        "mail": ["subject", "content"],
        "inApp": ["title", "content"],
    ]

    /// Grammar: `%recipients:([A-Za-z0-9_]+)%`, mirroring `PlaceholderExtractor`'s
    /// `%[A-Za-z0-9_]+%` content-placeholder grammar. Safe to force-unwrap: fixed valid literal.
    private static let recipientsTokenRegex = try! NSRegularExpression(pattern: "^%recipients:([A-Za-z0-9_]+)%$")

    /// `nil` when `raw` isn't shaped like a `%recipients:X%` token — the caller then falls back to
    /// treating `raw` as a plain field-name identifier.
    private static func recipientsVariableToken(_ raw: String) -> String? {
        let nsRaw = raw as NSString
        let fullRange = NSRange(location: 0, length: nsRaw.length)
        guard let match = recipientsTokenRegex.firstMatch(in: raw, range: fullRange),
              match.numberOfRanges > 1 else {
            return nil
        }
        return nsRaw.substring(with: match.range(at: 1))
    }
```

Then change:

```swift
                let recipients: [String] = entryMapping?["recipients"]?.sequence?.compactMap { $0.string } ?? []
                guard !recipients.isEmpty else {
                    throw NotificationParseError.emptyRecipients(event: eventName, type: type)
                }
                for recipient in recipients {
                    try IdentifierValidation.validate(recipient, kind: .recipient)
                }
```

to:

```swift
                let rawRecipients: [String] = entryMapping?["recipients"]?.sequence?.compactMap { $0.string } ?? []
                guard !rawRecipients.isEmpty else {
                    throw NotificationParseError.emptyRecipients(event: eventName, type: type)
                }
                var recipients: [RecipientSource] = []
                for raw in rawRecipients {
                    if let variableName = Self.recipientsVariableToken(raw) {
                        recipients.append(.variable(variableName))
                    } else {
                        try IdentifierValidation.validate(raw, kind: .recipient)
                        recipients.append(.field(raw))
                    }
                }
```

(The one other reference to `recipients` later in the same loop —
`notifications.append(NotificationEntry(type: type, render: render, recipients: recipients,
fields: fields))` — needs no change: it already just forwards the local `recipients` value, which
is now `[RecipientSource]`.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter NotificationParsingTests`
Expected: PASS (all pre-existing tests plus the 4 new ones). The pre-existing tests that assert
`mail.recipients == ["collaboratorId"]` must keep passing unmodified — `ExpressibleByStringLiteral`
makes the array literal on the right-hand side infer as `[RecipientSource]` and produce
`[.field("collaboratorId")]`, which matches what the parser now produces.

- [ ] **Step 6: Run the full DomainEventGenerator test target to confirm no regressions**

Run: `swift test --filter DomainEventGeneratorTests`
Expected: PASS. (`NotificationGeneratorTests.swift`'s existing `NotificationEntry(... recipients:
["collaboratorId"] ...)` fixtures at the top of that file must still compile — verify specifically,
since Task 4 will touch that same file's generator code but not its test fixtures.)

- [ ] **Step 7: Commit**

```bash
git add Sources/DomainEventGenerator/Generator/Notification/NotificationDefinitionFile.swift Tests/DomainEventGeneratorTests/NotificationParsingTests.swift
git commit -m "feat: notification.yaml parses %recipients:X% tokens"
```

---

### Task 4: `NotificationGenerator` — mixed recipients, typed inputs, cross-validation

**Files:**
- Modify: `Sources/DomainEventGenerator/Generator/Notification/NotificationGenerator.swift`
- Test: `Tests/DomainEventGeneratorTests/NotificationGeneratorTests.swift`

**Interfaces:**
- Consumes: `VariableDefinition.type: VariableType` and `.inputs` (Task 2); `NotificationEntry
  .recipients: [RecipientSource]` (Task 3).
- Produces: for every notification entry with at least one `.variable(X)` recipient, generated
  `recipients:` code of the shape `[<plain field expressions>] + (try await
  variables.<methodName>(<args>)) + ...`; for entries with none (every existing notification.yaml
  today), generated code is **byte-identical** to what `NotificationGenerator` emits today.

- [ ] **Step 1: Write failing tests**

Add to `Tests/DomainEventGeneratorTests/NotificationGeneratorTests.swift`:

```swift
    @Test("existing all-plain-field recipients render exactly as before mixed-recipients support existed")
    func plainRecipientsRenderUnchanged() throws {
        // Regression guard for the Global Constraint: token-free entries must not change output.
        let generator = NotificationGenerator(
            protocolName: "OpportunityNotificationVariables",
            events: [Self.collaboratorAddedEvent],
            variables: Self.variables
        )
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(output.contains(
            "RenderedNotification(\n                type: NotificationType(rawValue: \"mail\")!,\n                recipients: [input.collaboratorId],"))
    }

    @Test("a %recipients:X% token generates an awaited variable call concatenated with plain fields")
    func mixedRecipientsGenerateAwaitedCall() throws {
        let event = EventNotificationDefinition(
            eventName: "AssignedMemberAdded",
            notifications: [
                NotificationEntry(
                    type: "mail", render: .markdown,
                    recipients: ["memberIds", .variable("AssignedDepartmentMembers")],
                    fields: [(name: "subject", template: "hi"), (name: "content", template: "hi")]
                ),
            ]
        )
        let variables = [
            VariableDefinition(
                name: "AssignedDepartmentMembers", placeholder: "AssignedDepartmentMembers",
                type: .recipients,
                inputs: [(name: "quotingCaseGroupingId", type: "String"), (name: "eventMetadata", type: "Data")]
            ),
        ]
        let generator = NotificationGenerator(
            protocolName: "OpportunityNotificationVariables", events: [event], variables: variables)
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(output.contains(
            "recipients: [input.memberIds] + (try await variables.assignedDepartmentMembers(quotingCaseGroupingId: input.quotingCaseGroupingId, eventMetadata: input.eventMetadata)),"))
        // eventMetadata must be typed Data on the generated Input struct, not String.
        #expect(output.contains("internal let eventMetadata: Data"))
        #expect(output.contains("internal let quotingCaseGroupingId: String"))
    }

    @Test("a recipients list with only a %recipients:X% token (no plain fields) still generates valid code")
    func tokenOnlyRecipientsGenerate() throws {
        let event = EventNotificationDefinition(
            eventName: "AssignedMemberAdded",
            notifications: [
                NotificationEntry(
                    type: "mail", render: .markdown,
                    recipients: [.variable("AssignedDepartmentMembers")],
                    fields: [(name: "subject", template: "hi"), (name: "content", template: "hi")]
                ),
            ]
        )
        let variables = [
            VariableDefinition(
                name: "AssignedDepartmentMembers", placeholder: "AssignedDepartmentMembers",
                type: .recipients,
                inputs: [(name: "quotingCaseGroupingId", type: "String")]
            ),
        ]
        let generator = NotificationGenerator(
            protocolName: "OpportunityNotificationVariables", events: [event], variables: variables)
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(output.contains(
            "recipients: [] + (try await variables.assignedDepartmentMembers(quotingCaseGroupingId: input.quotingCaseGroupingId)),"))
    }

    @Test("a %recipients:X% token naming an undeclared variable throws undefinedRecipientsVariable")
    func undefinedRecipientsVariableThrows() {
        let event = EventNotificationDefinition(
            eventName: "AssignedMemberAdded",
            notifications: [
                NotificationEntry(
                    type: "mail", render: .markdown,
                    recipients: [.variable("NoSuchVariable")],
                    fields: [(name: "subject", template: "hi"), (name: "content", template: "hi")]
                ),
            ]
        )
        let generator = NotificationGenerator(protocolName: "P", events: [event], variables: [])
        #expect(throws: NotificationGenerateError.undefinedRecipientsVariable(event: "AssignedMemberAdded", variable: "NoSuchVariable")) {
            _ = try generator.render(accessLevel: .internal)
        }
    }

    @Test("a %recipients:X% token naming a type: environment variable throws recipientsVariableWrongType")
    func recipientsTokenOnEnvironmentVariableThrows() {
        let event = EventNotificationDefinition(
            eventName: "AssignedMemberAdded",
            notifications: [
                NotificationEntry(
                    type: "mail", render: .markdown,
                    recipients: [.variable("QuotingCaseGroupName")],
                    fields: [(name: "subject", template: "hi"), (name: "content", template: "hi")]
                ),
            ]
        )
        let generator = NotificationGenerator(protocolName: "P", events: [event], variables: Self.variables)
        #expect(throws: NotificationGenerateError.recipientsVariableWrongType(event: "AssignedMemberAdded", variable: "QuotingCaseGroupName")) {
            _ = try generator.render(accessLevel: .internal)
        }
    }

    @Test("a type: recipients variable's placeholder used in a text template throws recipientsVariableUsedAsPlaceholder")
    func recipientsVariableUsedAsPlaceholderThrows() {
        let event = EventNotificationDefinition(
            eventName: "AssignedMemberAdded",
            notifications: [
                NotificationEntry(
                    type: "mail", render: .markdown,
                    recipients: ["memberIds"],
                    fields: [(name: "subject", template: "%AssignedDepartmentMembers%"), (name: "content", template: "hi")]
                ),
            ]
        )
        let variables = [
            VariableDefinition(
                name: "AssignedDepartmentMembers", placeholder: "AssignedDepartmentMembers",
                type: .recipients, inputs: []
            ),
        ]
        let generator = NotificationGenerator(protocolName: "P", events: [event], variables: variables)
        #expect(throws: NotificationGenerateError.recipientsVariableUsedAsPlaceholder(event: "AssignedMemberAdded", placeholder: "AssignedDepartmentMembers")) {
            _ = try generator.render(accessLevel: .internal)
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter NotificationGeneratorTests`
Expected: FAIL to compile (`NotificationGenerateError.undefinedRecipientsVariable` etc. don't exist;
`recipients: ["memberIds", .variable(...)]` needs `RecipientSource`, already present from Task 3)
or fail at runtime (mixed-recipients output doesn't match; `eventMetadata` property missing/wrong
type).

- [ ] **Step 3: Add the new generation errors**

In `Sources/DomainEventGenerator/Generator/Notification/NotificationGenerator.swift`, change:

```swift
package enum NotificationGenerateError: Error, Equatable, Sendable {
    case undefinedPlaceholder(event: String, placeholder: String)
}

extension NotificationGenerateError: CustomStringConvertible {
    package var description: String {
        switch self {
        case .undefinedPlaceholder(let event, let placeholder):
            return "event '\(event)': placeholder '%\(placeholder)%' has no matching variable in variables.yaml"
        }
    }
}
```

to:

```swift
package enum NotificationGenerateError: Error, Equatable, Sendable {
    case undefinedPlaceholder(event: String, placeholder: String)
    case recipientsVariableUsedAsPlaceholder(event: String, placeholder: String)
    case undefinedRecipientsVariable(event: String, variable: String)
    case recipientsVariableWrongType(event: String, variable: String)
}

extension NotificationGenerateError: CustomStringConvertible {
    package var description: String {
        switch self {
        case .undefinedPlaceholder(let event, let placeholder):
            return "event '\(event)': placeholder '%\(placeholder)%' has no matching variable in variables.yaml"
        case .recipientsVariableUsedAsPlaceholder(let event, let placeholder):
            return "event '\(event)': '%\(placeholder)%' is a type: recipients variable and cannot be used inside a text template — use %recipients:\(placeholder)% in a recipients: list instead"
        case .undefinedRecipientsVariable(let event, let variable):
            return "event '\(event)': %recipients:\(variable)% has no matching variable in variables.yaml"
        case .recipientsVariableWrongType(let event, let variable):
            return "event '\(event)': %recipients:\(variable)% names a type: environment variable — only type: recipients variables can be used in a recipients: list"
        }
    }
}
```

- [ ] **Step 4: Rework `render()`'s property/validation bookkeeping and dispatch to the new struct/enum renderers**

In the same file, change:

```swift
    package func render(accessLevel: AccessLevel) throws -> [String] {
        let access = accessLevel.rawValue
        let variablesByPlaceholder = Dictionary(uniqueKeysWithValues: variables.map { ($0.placeholder, $0) })
        let sortedEvents = events.sorted { $0.eventName < $1.eventName }

        var lines: [String] = ["import NotificationDefinition"]

        for event in sortedEvents {
            // Distinct placeholders referenced by this event, in first-appearance order across
            // all notification entries/fields (order only matters for validation; declaration
            // order in the generated code is alphabetical for determinism — see below).
            var orderedPlaceholders: [String] = []
            var seenPlaceholders: Set<String> = []
            for entry in event.notifications {
                for field in entry.fields {
                    for placeholder in PlaceholderExtractor.placeholders(in: field.template) {
                        if seenPlaceholders.insert(placeholder).inserted {
                            orderedPlaceholders.append(placeholder)
                        }
                    }
                }
            }

            // Every placeholder becomes a `let <lowerCamel(placeholder)> = ...` local in the
            // generated `render()` — validate that transform is a legal, non-reserved Swift
            // identifier, and that no two distinct placeholders collide on it.
            var localNamesByPlaceholder: [String: String] = [:]
            for placeholder in orderedPlaceholders {
                try IdentifierValidation.validateLowerCamel(placeholder, kind: .placeholder)
                let localName = IdentifierValidation.lowerCamel(placeholder)
                if let existing = localNamesByPlaceholder[localName] {
                    throw IdentifierValidationError.identifierCollision(a: existing, b: placeholder)
                }
                localNamesByPlaceholder[localName] = placeholder
            }

            var matchedVariables: [VariableDefinition] = []
            for placeholder in orderedPlaceholders {
                guard let variable = variablesByPlaceholder[placeholder] else {
                    throw NotificationGenerateError.undefinedPlaceholder(event: event.eventName, placeholder: placeholder)
                }
                matchedVariables.append(variable)
            }

            let sortedPlaceholders = orderedPlaceholders.sorted()

            var propertyNames: Set<String> = []
            for notification in event.notifications {
                for recipient in notification.recipients {
                    propertyNames.insert(recipient)
                }
            }
            for variable in matchedVariables {
                for input in variable.inputs {
                    propertyNames.insert(input.name)
                }
            }
            let sortedProperties = propertyNames.sorted()

            lines.append(Self.renderInputStruct(access: access, event: event, properties: sortedProperties))
            lines.append(
                Self.renderNotificationEnum(
                    access: access,
                    protocolName: protocolName,
                    event: event,
                    properties: sortedProperties,
                    placeholders: sortedPlaceholders
                ))
        }

        return lines
    }
```

to:

```swift
    package func render(accessLevel: AccessLevel) throws -> [String] {
        let access = accessLevel.rawValue
        let variablesByPlaceholder = Dictionary(uniqueKeysWithValues: variables.map { ($0.placeholder, $0) })
        let variablesByName = Dictionary(uniqueKeysWithValues: variables.map { ($0.name, $0) })
        let sortedEvents = events.sorted { $0.eventName < $1.eventName }

        var lines: [String] = ["import NotificationDefinition"]

        for event in sortedEvents {
            // Distinct placeholders referenced by this event, in first-appearance order across
            // all notification entries/fields (order only matters for validation; declaration
            // order in the generated code is alphabetical for determinism — see below).
            var orderedPlaceholders: [String] = []
            var seenPlaceholders: Set<String> = []
            for entry in event.notifications {
                for field in entry.fields {
                    for placeholder in PlaceholderExtractor.placeholders(in: field.template) {
                        if seenPlaceholders.insert(placeholder).inserted {
                            orderedPlaceholders.append(placeholder)
                        }
                    }
                }
            }

            // Every placeholder becomes a `let <lowerCamel(placeholder)> = ...` local in the
            // generated `render()` — validate that transform is a legal, non-reserved Swift
            // identifier, and that no two distinct placeholders collide on it.
            var localNamesByPlaceholder: [String: String] = [:]
            for placeholder in orderedPlaceholders {
                try IdentifierValidation.validateLowerCamel(placeholder, kind: .placeholder)
                let localName = IdentifierValidation.lowerCamel(placeholder)
                if let existing = localNamesByPlaceholder[localName] {
                    throw IdentifierValidationError.identifierCollision(a: existing, b: placeholder)
                }
                localNamesByPlaceholder[localName] = placeholder
            }

            var matchedVariables: [VariableDefinition] = []
            for placeholder in orderedPlaceholders {
                guard let variable = variablesByPlaceholder[placeholder] else {
                    throw NotificationGenerateError.undefinedPlaceholder(event: event.eventName, placeholder: placeholder)
                }
                guard variable.type == .environment else {
                    throw NotificationGenerateError.recipientsVariableUsedAsPlaceholder(event: event.eventName, placeholder: placeholder)
                }
                matchedVariables.append(variable)
            }

            let sortedPlaceholders = orderedPlaceholders.sorted()

            // Every `%recipients:X%` token referenced by this event's recipients: lists, matched
            // and type-checked against variables.yaml — mirrors matchedVariables above.
            var matchedRecipientsVariables: [VariableDefinition] = []
            var seenRecipientsVariableNames: Set<String> = []
            for notification in event.notifications {
                for recipient in notification.recipients {
                    guard case .variable(let variableName) = recipient else { continue }
                    guard let variable = variablesByName[variableName] else {
                        throw NotificationGenerateError.undefinedRecipientsVariable(event: event.eventName, variable: variableName)
                    }
                    guard variable.type == .recipients else {
                        throw NotificationGenerateError.recipientsVariableWrongType(event: event.eventName, variable: variableName)
                    }
                    if seenRecipientsVariableNames.insert(variableName).inserted {
                        matchedRecipientsVariables.append(variable)
                    }
                }
            }

            // Every Input struct property, with its Swift type — almost always "String", except
            // a type: recipients variable's `$event.metadata` input, typed "Data".
            var propertyTypes: [String: String] = [:]
            for notification in event.notifications {
                for recipient in notification.recipients {
                    if case .field(let name) = recipient {
                        propertyTypes[name] = "String"
                    }
                }
            }
            for variable in matchedVariables {
                for input in variable.inputs {
                    propertyTypes[input.name] = input.type
                }
            }
            for variable in matchedRecipientsVariables {
                for input in variable.inputs {
                    propertyTypes[input.name] = input.type
                }
            }
            let sortedProperties: [(name: String, type: String)] =
                propertyTypes.keys.sorted().map { (name: $0, type: propertyTypes[$0]!) }

            lines.append(Self.renderInputStruct(access: access, event: event, properties: sortedProperties))
            lines.append(
                Self.renderNotificationEnum(
                    access: access,
                    protocolName: protocolName,
                    event: event,
                    properties: sortedProperties,
                    placeholders: sortedPlaceholders,
                    variablesByName: variablesByName
                ))
        }

        return lines
    }
```

- [ ] **Step 5: Update `renderInputStruct` for typed properties**

In the same file, change:

```swift
    private static func renderInputStruct(access: String, event: EventNotificationDefinition, properties: [String]) -> String {
        var lines = ["\(access) struct \(event.eventName)NotificationInput: Decodable {"]
        for property in properties {
            lines.append("    \(access) let \(property): String")
        }
        lines.append("")
        let parameterList = properties.map { "\($0): String" }.joined(separator: ", ")
        lines.append("    \(access) init(\(parameterList)) {")
        for property in properties {
            lines.append("        self.\(property) = \(property)")
        }
        lines.append("    }")
        lines.append("}")
        return lines.joined(separator: "\n")
    }
```

to:

```swift
    private static func renderInputStruct(
        access: String, event: EventNotificationDefinition, properties: [(name: String, type: String)]
    ) -> String {
        var lines = ["\(access) struct \(event.eventName)NotificationInput: Decodable {"]
        for property in properties {
            lines.append("    \(access) let \(property.name): \(property.type)")
        }
        lines.append("")
        let parameterList = properties.map { "\($0.name): \($0.type)" }.joined(separator: ", ")
        lines.append("    \(access) init(\(parameterList)) {")
        for property in properties {
            lines.append("        self.\(property.name) = \(property.name)")
        }
        lines.append("    }")
        lines.append("}")
        return lines.joined(separator: "\n")
    }
```

- [ ] **Step 6: Update `renderNotificationEnum` for typed properties and mixed recipients**

In the same file, change:

```swift
    private static func renderNotificationEnum(
        access: String,
        protocolName: String,
        event: EventNotificationDefinition,
        properties: [String],
        placeholders: [String]
    ) -> String {
        var lines = ["\(access) enum \(event.eventName)Notification {"]

        // render(input:variables:)
        lines.append(
            "    \(access) static func render(input: \(event.eventName)NotificationInput, variables: some \(protocolName)) async throws -> [RenderedNotification] {")

        if !placeholders.isEmpty {
            lines.append("        let inputs: [String: String] = [")
            for property in properties {
                lines.append("            \"\(property)\": input.\(property),")
            }
            lines.append("        ]")
        }
```

to:

```swift
    private static func renderNotificationEnum(
        access: String,
        protocolName: String,
        event: EventNotificationDefinition,
        properties: [(name: String, type: String)],
        placeholders: [String],
        variablesByName: [String: VariableDefinition]
    ) -> String {
        var lines = ["\(access) enum \(event.eventName)Notification {"]

        // render(input:variables:)
        lines.append(
            "    \(access) static func render(input: \(event.eventName)NotificationInput, variables: some \(protocolName)) async throws -> [RenderedNotification] {")

        if !placeholders.isEmpty {
            // Only String-typed properties can populate the __value seam's [String: String]
            // inputs dictionary — a type: recipients variable's Data-typed eventMetadata (if any
            // property happens to be named that) never participates in text-template resolution.
            lines.append("        let inputs: [String: String] = [")
            for property in properties where property.type == "String" {
                lines.append("            \"\(property.name)\": input.\(property.name),")
            }
            lines.append("        ]")
        }
```

Then change:

```swift
        lines.append("        return [")
        for entry in event.notifications {
            let recipientExpressions = entry.recipients.map { "input.\($0)" }.joined(separator: ", ")
            lines.append("            RenderedNotification(")
            lines.append("                type: NotificationType(rawValue: \"\(entry.type)\")!,")
            lines.append("                recipients: [\(recipientExpressions)],")
```

to:

```swift
        lines.append("        return [")
        for entry in event.notifications {
            let fieldRecipients: [String] = entry.recipients.compactMap {
                guard case .field(let name) = $0 else { return nil }
                return "input.\(name)"
            }
            let variableRecipients: [String] = entry.recipients.compactMap { source in
                guard case .variable(let variableName) = source, let variable = variablesByName[variableName] else {
                    return nil
                }
                let arguments = variable.inputs.map { "\($0.name): input.\($0.name)" }.joined(separator: ", ")
                return "try await variables.\(Self.lowerCamel(variable.name))(\(arguments))"
            }
            let recipientsExpression: String
            if variableRecipients.isEmpty {
                // Unchanged from before mixed-recipients support existed — keeps every
                // token-free notification.yaml's generated code byte-identical.
                recipientsExpression = "[\(fieldRecipients.joined(separator: ", "))]"
            } else {
                var parts = ["[\(fieldRecipients.joined(separator: ", "))]"]
                parts.append(contentsOf: variableRecipients.map { "(\($0))" })
                recipientsExpression = parts.joined(separator: " + ")
            }
            lines.append("            RenderedNotification(")
            lines.append("                type: NotificationType(rawValue: \"\(entry.type)\")!,")
            lines.append("                recipients: \(recipientsExpression),")
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test --filter NotificationGeneratorTests`
Expected: PASS (all pre-existing tests plus the 6 new ones).

- [ ] **Step 8: Run the full DomainEventGenerator test target to confirm no regressions**

Run: `swift test --filter DomainEventGeneratorTests`
Expected: PASS.

- [ ] **Step 9: Run the full package test suite**

Run: `swift test`
Expected: PASS — every target across the repo (ContextForwarder, DomainEventGenerator, and any
others) green.

- [ ] **Step 10: Commit**

```bash
git add Sources/DomainEventGenerator/Generator/Notification/NotificationGenerator.swift Tests/DomainEventGeneratorTests/NotificationGeneratorTests.swift
git commit -m "feat: notification.yaml mixed recipients, typed inputs, cross-validation"
```

---

## Self-Review Notes (for the plan author, already applied above)

- **Spec coverage:** §2 → Task 1. §3.1/§3.2/§3.3 → Task 2. §4.1/§4.2 → Task 3. §4.3/§4.4/§5 → Task
  4 (§4.4's OC-side interaction is explicitly out of scope for this plan — swift-ddd-kit only, per
  spec §6.2 — nothing to do here beyond noting the mechanisms don't conflict, which the design
  already ensures since Task 4's recipients-building runs entirely inside `render()`, before any
  OC-side post-render override sees the result). §6 migration order → this plan is exactly step 2
  (step 1/Task 1 bundled in since both are additive and small). §7 testing plan → covered by each
  task's test steps; the OC-side test from §7's last bullet is explicitly deferred to whatever plan
  implements spec §6.3 (OC adoption), not this one.
- **Type consistency:** `VariableDefinition.type`/`VariableType` (Task 2) is consumed by name in
  Task 4 exactly as declared. `RecipientSource` (Task 3) is consumed by name in Task 4 exactly as
  declared. `sortedProperties`'s type changes from `[String]` to `[(name: String, type: String)]`
  consistently across `render()`, `renderInputStruct`, and `renderNotificationEnum` within Task 4 —
  no stale `[String]` usage left behind.
- **No placeholders:** every step above contains complete, concrete code — no "add appropriate
  validation" or "similar to Task N" placeholders.
