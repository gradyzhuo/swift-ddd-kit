# Per-Entry Notification Recipients Protocol Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `notification.yaml`'s `recipients:` field with a required `id:` per entry, and
change `NotificationGenerator` to emit — per entry, not per event — a protocol the consumer
implements directly (exposing the real `DomainEvent`, known text-template fields, a
`recipients()` requirement, and an overridable `render()`), instead of a shared `Decodable` Input
struct plus a single event-level `render(input:variables:)`.

**Architecture:** Three changes to the DomainEventGenerator's notification-definition
sub-generator: (1) `notification.yaml` parsing drops `recipients:`, adds `id:` (required, unique
per event, restricted charset); (2) `NotificationGenerator` restructures its per-event loop into a
per-entry loop, computing each entry's own known-field set from only that entry's own templates,
and emits a protocol + default-implementation extension instead of an Input struct + free
function; (3) the demo target and README are updated to exercise and document the new shape,
including a real (hand-written) `DomainEvent`-conforming type, since the framework's generated
code now references `DDDCore.DomainEvent` directly.

**Tech Stack:** Swift 6, Yams (YAML parsing), swift-testing (`@Test`/`@Suite`/`#expect`).

**Spec:** `docs/superpowers/specs/2026-09-19-per-entry-notification-recipients-protocol-design.md`
(NotificationContext repo — read it there; not duplicated into this repo).

## Global Constraints

- `id:` is **required** on every `notification.yaml` entry, must match
  `^[a-z][a-z0-9_-]*$`, and must be unique among the entries of the **same event** (not required
  unique across different events).
- `recipients:` is **no longer a legal key** on a notification entry — if present, it is reported
  via the existing `NotificationParseError.extraField` mechanism (it's simply removed from the
  type's `allowedKeys`).
- Known-field properties on a generated protocol are derived **per entry** (from only that
  entry's own `subject`/`title`/`content` templates' referenced variables), not per event —
  this is a behavior change from before: two entries of the same event may now generate
  different known-field sets.
- The generated protocol's `recipients()` and `render(variables:)` are BOTH declared as protocol
  requirements (not only provided via an extension) — `render(variables:)` additionally has a
  default implementation in an extension, so a conformer that doesn't override it gets the
  default, and one that does override it is correctly selected via dynamic dispatch. `recipients()`
  has no default — every conformer must implement it.
- Protocol naming: `\(EventName)Notification\(IdPascal)Protocol`, where `IdPascal` is `id` split on
  `-`/`_`, each segment's first letter uppercased, rejoined with `_` (e.g. `test-abc-mail` →
  `Test_Abc_Mail`).
- Two entries in the same event whose `id`s produce the SAME `IdPascal` string (e.g. `test-abc` and
  `test_abc` both become `Test_Abc`) is a **generation-time error**, not silently-colliding
  generated code.
- The environment-variable mechanism (`variables.yaml`, `%Placeholder%` text substitution,
  `VariablesProtocolGenerator`'s `__value(of:inputs:)` seam) is **completely unchanged** by this
  plan — do not touch `VariablesDefinition.swift` or `VariablesProtocolGenerator.swift`.
- `ForwardedRecord.customMetadata` does **not** exist on this branch and is **out of scope** for
  this plan — it was PR #17's Task 1, superseded PR closed, not part of this design.

---

### Task 1: `notification.yaml` — `id:` required, `recipients:` removed

**Files:**
- Modify: `Sources/DomainEventGenerator/Generator/Notification/NotificationDefinitionFile.swift`
- Modify: `Sources/DomainEventGenerator/Generator/Notification/IdentifierValidation.swift`
- Test: `Tests/DomainEventGeneratorTests/NotificationParsingTests.swift`

**Interfaces:**
- Produces: `NotificationEntry.id: String` (replaces `NotificationEntry.recipients: [String]`,
  which is removed entirely). `NotificationParseError` gains `missingId(event: String, type:
  String)`, `invalidId(event: String, id: String)`, `duplicateId(event: String, id: String)`;
  loses `emptyRecipients(event:type:)`.
- Consumes: nothing new from other tasks — this task is independent of Task 2/3 at compile time
  (Task 2 consumes `NotificationEntry.id` and the removal of `.recipients`, but Task 1 itself
  doesn't need anything from Task 2).

- [ ] **Step 1: Remove the now-unused `.recipient` `IdentifierKind` case**

In `Sources/DomainEventGenerator/Generator/Notification/IdentifierValidation.swift`, change:

```swift
package enum IdentifierKind: String, Sendable, Equatable {
    case eventName = "event name"
    case recipient = "recipient"
    case variableName = "variable"
    case inputName = "input"
    case placeholder = "placeholder"
}
```

to:

```swift
package enum IdentifierKind: String, Sendable, Equatable {
    case eventName = "event name"
    case variableName = "variable"
    case inputName = "input"
    case placeholder = "placeholder"
}
```

and change the `CustomStringConvertible` switch:

```swift
            case .eventName, .recipient, .inputName:
                return "\(kind.rawValue) '\(name)' is not a valid Swift identifier"
```

to:

```swift
            case .eventName, .inputName:
                return "\(kind.rawValue) '\(name)' is not a valid Swift identifier"
```

(`id:` values are validated by a dedicated regex in this task's Step 3, not by
`IdentifierValidation` — `id` legally contains `-`, which is not a valid Swift identifier
character, so it can never reuse `IdentifierValidation.validate`.)

- [ ] **Step 2: Write the failing parser tests**

Replace the entire contents of `Tests/DomainEventGeneratorTests/NotificationParsingTests.swift`
with:

```swift
import Testing
import Foundation
import Yams
@testable import DomainEventGenerator

@Suite("Notification YAML Parsing")
struct NotificationParsingTests {

    // Spec sample, updated for per-entry protocol `id`.
    static let specSampleYAML = """
    CollaboratorAdded:
      notifications:
        - id: collaborator-added-mail
          type: mail
          subject: 你已被加入案件「%QuotingCaseGroupName%」
          content: |
            你以「%QuotingCaseGroupCollaboratorRole%」角色被加入案件「%QuotingCaseGroupName%」，%CollaboratorDescription%。
        - id: collaborator-added-in-app
          type: inApp
          title: 你已被加入案件「%QuotingCaseGroupName%」
          content: 你以「%QuotingCaseGroupCollaboratorRole%」角色被加入案件「%QuotingCaseGroupName%」。
    """

    @Test("spec sample decodes: id per-entry, both notification types, exact fields")
    func specSampleDecodes() throws {
        let definitions = try NotificationDefinitionParser.parse(yaml: Self.specSampleYAML)
        #expect(definitions.count == 1)
        let definition = try #require(definitions.first)

        #expect(definition.eventName == "CollaboratorAdded")
        #expect(definition.notifications.count == 2)

        let mail = definition.notifications[0]
        #expect(mail.id == "collaborator-added-mail")
        #expect(mail.type == "mail")
        #expect(mail.fields.map(\.name) == ["subject", "content"])
        #expect(mail.fields[0].template == "你已被加入案件「%QuotingCaseGroupName%」")
        #expect(mail.fields[1].template.contains("%QuotingCaseGroupCollaboratorRole%"))
        #expect(mail.fields[1].template.contains("%QuotingCaseGroupName%"))
        #expect(mail.fields[1].template.contains("%CollaboratorDescription%"))

        let inApp = definition.notifications[1]
        #expect(inApp.id == "collaborator-added-in-app")
        #expect(inApp.type == "inApp")
        #expect(inApp.fields.map(\.name) == ["title", "content"])
        #expect(inApp.fields[0].template == "你已被加入案件「%QuotingCaseGroupName%」")
        #expect(inApp.fields[1].template == "你以「%QuotingCaseGroupCollaboratorRole%」角色被加入案件「%QuotingCaseGroupName%」。")
    }

    @Test("unknown notification type throws unknownType")
    func unknownTypeThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-entry
              type: push
              subject: hi
        """
        #expect(throws: NotificationParseError.unknownType(event: "SomeEvent", type: "push")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("duplicate notification type in the same event throws duplicateType")
    func duplicateTypeThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: first-mail
              type: mail
              subject: hi
              content: body
            - id: second-mail
              type: mail
              subject: hi again
              content: body again
        """
        #expect(throws: NotificationParseError.duplicateType(event: "SomeEvent", type: "mail")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("mail entry missing content throws missingField")
    func missingFieldThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-mail
              type: mail
              subject: hi
        """
        #expect(throws: NotificationParseError.missingField(event: "SomeEvent", type: "mail", field: "content")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("inApp entry missing title throws missingField")
    func missingFieldInAppThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-in-app
              type: inApp
              content: hi
        """
        #expect(throws: NotificationParseError.missingField(event: "SomeEvent", type: "inApp", field: "title")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("mail entry with extra field throws extraField")
    func extraFieldThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-mail
              type: mail
              subject: hi
              content: body
              cc: someone
        """
        #expect(throws: NotificationParseError.extraField(event: "SomeEvent", type: "mail", field: "cc")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("inApp entry with extra field throws extraField")
    func extraFieldInAppThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-in-app
              type: inApp
              title: hi
              content: body
              icon: bell
        """
        #expect(throws: NotificationParseError.extraField(event: "SomeEvent", type: "inApp", field: "icon")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("a recipients: key on an entry throws extraField — schema no longer supports it")
    func recipientsKeyThrowsExtraField() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-mail
              type: mail
              recipients:
                - userId
              subject: hi
              content: body
        """
        #expect(throws: NotificationParseError.extraField(event: "SomeEvent", type: "mail", field: "recipients")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("missing id key on entry throws missingId")
    func missingIdThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - type: mail
              subject: hi
              content: body
        """
        #expect(throws: NotificationParseError.missingId(event: "SomeEvent", type: "mail")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("empty id value on entry throws missingId")
    func emptyIdThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: ""
              type: mail
              subject: hi
              content: body
        """
        #expect(throws: NotificationParseError.missingId(event: "SomeEvent", type: "mail")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("id starting with an uppercase letter throws invalidId")
    func idStartingUppercaseThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: Some-Mail
              type: mail
              subject: hi
              content: body
        """
        #expect(throws: NotificationParseError.invalidId(event: "SomeEvent", id: "Some-Mail")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("id starting with a digit throws invalidId")
    func idStartingDigitThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: "1st-mail"
              type: mail
              subject: hi
              content: body
        """
        #expect(throws: NotificationParseError.invalidId(event: "SomeEvent", id: "1st-mail")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("id containing an illegal character throws invalidId")
    func idContainingIllegalCharacterThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: "some mail"
              type: mail
              subject: hi
              content: body
        """
        #expect(throws: NotificationParseError.invalidId(event: "SomeEvent", id: "some mail")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("duplicate id within the same event throws duplicateId")
    func duplicateIdThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: same-id
              type: mail
              subject: hi
              content: body
            - id: same-id
              type: inApp
              title: hi
              content: body
        """
        #expect(throws: NotificationParseError.duplicateId(event: "SomeEvent", id: "same-id")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("the same id may be reused across different events")
    func sameIdAcrossDifferentEventsIsAllowed() throws {
        let yaml = """
        EventA:
          notifications:
            - id: shared-id
              type: mail
              subject: hi
              content: body
        EventB:
          notifications:
            - id: shared-id
              type: mail
              subject: hi
              content: body
        """
        let definitions = try NotificationDefinitionParser.parse(yaml: yaml)
        #expect(definitions.count == 2)
        #expect(definitions.allSatisfy { $0.notifications[0].id == "shared-id" })
    }

    @Test("empty notifications list throws emptyNotifications")
    func emptyNotificationsThrows() {
        let yaml = """
        SomeEvent:
          notifications: []
        """
        #expect(throws: NotificationParseError.emptyNotifications(event: "SomeEvent")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }

    @Test("missing notifications key throws emptyNotifications")
    func missingNotificationsKeyThrows() {
        let yaml = """
        SomeEvent: {}
        """
        #expect(throws: NotificationParseError.emptyNotifications(event: "SomeEvent")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }
}

@Suite("Notification YAML render: parsing")
struct NotificationRenderParsingTests {

    @Test("mail entry defaults render to markdown when omitted")
    func mailDefaultsToMarkdown() throws {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-mail
              type: mail
              subject: hi
              content: body
        """
        let definitions = try NotificationDefinitionParser.parse(yaml: yaml)
        #expect(definitions[0].notifications[0].render == .markdown)
    }

    @Test("inApp entry defaults render to plaintext when omitted")
    func inAppDefaultsToPlaintext() throws {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-in-app
              type: inApp
              title: hi
              content: body
        """
        let definitions = try NotificationDefinitionParser.parse(yaml: yaml)
        #expect(definitions[0].notifications[0].render == .plaintext)
    }

    @Test("mail entry may explicitly declare render: plaintext")
    func mailExplicitPlaintext() throws {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-mail
              type: mail
              render: plaintext
              subject: hi
              content: body
        """
        let definitions = try NotificationDefinitionParser.parse(yaml: yaml)
        #expect(definitions[0].notifications[0].render == .plaintext)
    }

    @Test("inApp entry may explicitly declare render: markdown")
    func inAppExplicitMarkdown() throws {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-in-app
              type: inApp
              render: markdown
              title: hi
              content: body
        """
        let definitions = try NotificationDefinitionParser.parse(yaml: yaml)
        #expect(definitions[0].notifications[0].render == .markdown)
    }

    @Test("invalid render value throws invalidRenderFormat")
    func invalidRenderValueThrows() {
        let yaml = """
        SomeEvent:
          notifications:
            - id: some-mail
              type: mail
              render: html
              subject: hi
              content: body
        """
        #expect(throws: NotificationParseError.invalidRenderFormat(event: "SomeEvent", type: "mail", value: "html")) {
            _ = try NotificationDefinitionParser.parse(yaml: yaml)
        }
    }
}

@Suite("PlaceholderExtractor")
struct PlaceholderExtractorTests {

    @Test("extracts placeholders in first-appearance order, deduplicated")
    func extractsOrderedDeduplicated() {
        let template = "你以「%QuotingCaseGroupCollaboratorRole%」角色被加入案件「%QuotingCaseGroupName%」，%CollaboratorDescription%。再次提及 %QuotingCaseGroupName%。"
        let placeholders = PlaceholderExtractor.placeholders(in: template)
        #expect(placeholders == ["QuotingCaseGroupCollaboratorRole", "QuotingCaseGroupName", "CollaboratorDescription"])
    }

    @Test("no placeholders returns empty array")
    func noPlaceholdersReturnsEmpty() {
        #expect(PlaceholderExtractor.placeholders(in: "plain text, no tokens here") == [])
    }

    @Test("adjacent tokens are both extracted")
    func adjacentTokensExtracted() {
        #expect(PlaceholderExtractor.placeholders(in: "%A%%B%") == ["A", "B"])
    }

    @Test("non-token percent signs are ignored")
    func nonTokenPercentSignsIgnored() {
        #expect(PlaceholderExtractor.placeholders(in: "50%% off %A% 100% sure") == ["A"])
    }
}
```

(The old `NotificationDefinitionParserIdentifierValidationTests` suite, which tested a
`recipients:` entry that wasn't a valid Swift identifier, is deleted — that code path no longer
exists. Its coverage intent is replaced by this file's `idStartingUppercaseThrows`/
`idStartingDigitThrows`/`idContainingIllegalCharacterThrows` tests.)

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter NotificationParsingTests`
Expected: FAIL to compile — `NotificationEntry` has no member `id`, `NotificationParseError` has
no case `missingId`/`invalidId`/`duplicateId`.

- [ ] **Step 4: Update `NotificationEntry` and `NotificationParseError`**

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
/// One channel entry (`mail`/`inApp`) for a single event, with its fields in the type's
/// canonical schema order (`mail`: subject, content; `inApp`: title, content). `id` is this
/// entry's own identifier, unique among the entries of the same event — used to derive the
/// generated per-entry protocol's name (see `NotificationGenerator`).
package struct NotificationEntry: Equatable {
    package let id: String
    package let type: String
    package let render: NotificationRenderFormat
    package let fields: [(name: String, template: String)]

    package init(
        id: String, type: String, render: NotificationRenderFormat,
        fields: [(name: String, template: String)]
    ) {
        self.id = id
        self.type = type
        self.render = render
        self.fields = fields
    }

    package static func == (lhs: NotificationEntry, rhs: NotificationEntry) -> Bool {
        lhs.id == rhs.id
            && lhs.type == rhs.type
            && lhs.render == rhs.render
            && lhs.fields.count == rhs.fields.count
            && zip(lhs.fields, rhs.fields).allSatisfy { $0.name == $1.name && $0.template == $1.template }
    }
}
```

Then change:

```swift
package enum NotificationParseError: Error, Equatable, Sendable {
    case unknownType(event: String, type: String)
    case duplicateType(event: String, type: String)
    case missingField(event: String, type: String, field: String)
    case extraField(event: String, type: String, field: String)
    case invalidRenderFormat(event: String, type: String, value: String)
    case emptyRecipients(event: String, type: String)
    case emptyNotifications(event: String)
}

extension NotificationParseError: CustomStringConvertible {
    package var description: String {
        switch self {
        case .unknownType(let event, let type):
            if type.isEmpty {
                return "event '\(event)': notification entry is missing its `type` key"
            }
            return "event '\(event)': unknown notification type '\(type)' (expected 'mail' or 'inApp')"
        case .duplicateType(let event, let type):
            return "event '\(event)': notification type '\(type)' is declared more than once"
        case .missingField(let event, let type, let field):
            return "event '\(event)': notification type '\(type)' is missing required field '\(field)'"
        case .extraField(let event, let type, let field):
            return "event '\(event)': notification type '\(type)' has unexpected field '\(field)'"
        case .invalidRenderFormat(let event, let type, let value):
            return "event '\(event)': notification type '\(type)' has invalid `render` value '\(value)' (expected 'markdown' or 'plaintext')"
        case .emptyRecipients(let event, let type):
            return "event '\(event)': notification type '\(type)' has empty `recipients`"
        case .emptyNotifications(let event):
            return "event '\(event)': `notifications` must not be empty"
        }
    }
}
```

to:

```swift
package enum NotificationParseError: Error, Equatable, Sendable {
    case unknownType(event: String, type: String)
    case duplicateType(event: String, type: String)
    case missingField(event: String, type: String, field: String)
    case extraField(event: String, type: String, field: String)
    case invalidRenderFormat(event: String, type: String, value: String)
    case missingId(event: String, type: String)
    case invalidId(event: String, id: String)
    case duplicateId(event: String, id: String)
    case emptyNotifications(event: String)
}

extension NotificationParseError: CustomStringConvertible {
    package var description: String {
        switch self {
        case .unknownType(let event, let type):
            if type.isEmpty {
                return "event '\(event)': notification entry is missing its `type` key"
            }
            return "event '\(event)': unknown notification type '\(type)' (expected 'mail' or 'inApp')"
        case .duplicateType(let event, let type):
            return "event '\(event)': notification type '\(type)' is declared more than once"
        case .missingField(let event, let type, let field):
            return "event '\(event)': notification type '\(type)' is missing required field '\(field)'"
        case .extraField(let event, let type, let field):
            return "event '\(event)': notification type '\(type)' has unexpected field '\(field)'"
        case .invalidRenderFormat(let event, let type, let value):
            return "event '\(event)': notification type '\(type)' has invalid `render` value '\(value)' (expected 'markdown' or 'plaintext')"
        case .missingId(let event, let type):
            return "event '\(event)': notification type '\(type)' is missing required `id` key"
        case .invalidId(let event, let id):
            return "event '\(event)': id '\(id)' is not a valid id (expected lowercase letters/digits/'-'/'_' , starting with a lowercase letter)"
        case .duplicateId(let event, let id):
            return "event '\(event)': id '\(id)' is declared more than once"
        case .emptyNotifications(let event):
            return "event '\(event)': `notifications` must not be empty"
        }
    }
}
```

- [ ] **Step 5: Update the parser**

In the same file, change:

```swift
package enum NotificationDefinitionParser {

    /// Closed field schema per notification type, in canonical (generated-field) order.
    private static let typeSchemas: [String: [String]] = [
        "mail": ["subject", "content"],
        "inApp": ["title", "content"],
    ]

    package static func parse(yaml: String) throws -> [EventNotificationDefinition] {
        guard let root = try Yams.compose(yaml: yaml), let mapping = root.mapping else {
            return []
        }

        var definitions: [EventNotificationDefinition] = []

        for (keyNode, valueNode) in mapping {
            let eventName = keyNode.string ?? ""
            try IdentifierValidation.validate(eventName, kind: .eventName)
            let eventMapping = valueNode.mapping

            let notificationsSequence = eventMapping?["notifications"]?.sequence ?? []
            guard !notificationsSequence.isEmpty else {
                throw NotificationParseError.emptyNotifications(event: eventName)
            }

            var notifications: [NotificationEntry] = []
            var seenTypes: Set<String> = []
            for entryNode in notificationsSequence {
                let entryMapping = entryNode.mapping
                let type = entryMapping?["type"]?.string ?? ""

                guard let schemaFields = Self.typeSchemas[type] else {
                    throw NotificationParseError.unknownType(event: eventName, type: type)
                }
                guard seenTypes.insert(type).inserted else {
                    throw NotificationParseError.duplicateType(event: eventName, type: type)
                }

                let recipients: [String] = entryMapping?["recipients"]?.sequence?.compactMap { $0.string } ?? []
                guard !recipients.isEmpty else {
                    throw NotificationParseError.emptyRecipients(event: eventName, type: type)
                }
                for recipient in recipients {
                    try IdentifierValidation.validate(recipient, kind: .recipient)
                }

                let allowedKeys = Set(schemaFields).union(["type", "render", "recipients"])
                if let entryMapping {
                    for (fieldKeyNode, _) in entryMapping {
                        guard let fieldKey = fieldKeyNode.string else { continue }
                        guard allowedKeys.contains(fieldKey) else {
                            throw NotificationParseError.extraField(event: eventName, type: type, field: fieldKey)
                        }
                    }
                }

                let render: NotificationRenderFormat
                if let renderValue = entryMapping?["render"]?.string {
                    guard let parsed = NotificationRenderFormat(rawValue: renderValue) else {
                        throw NotificationParseError.invalidRenderFormat(event: eventName, type: type, value: renderValue)
                    }
                    render = parsed
                } else {
                    render = NotificationRenderFormat.defaultFormat(forType: type)
                }

                var fields: [(name: String, template: String)] = []
                for fieldName in schemaFields {
                    guard let template = entryMapping?[fieldName]?.string else {
                        throw NotificationParseError.missingField(event: eventName, type: type, field: fieldName)
                    }
                    fields.append((name: fieldName, template: template))
                }

                notifications.append(NotificationEntry(type: type, render: render, recipients: recipients, fields: fields))
            }

            definitions.append(EventNotificationDefinition(eventName: eventName, notifications: notifications))
        }

        return definitions
    }
}
```

to:

```swift
package enum NotificationDefinitionParser {

    /// Closed field schema per notification type, in canonical (generated-field) order.
    private static let typeSchemas: [String: [String]] = [
        "mail": ["subject", "content"],
        "inApp": ["title", "content"],
    ]

    /// `id:` grammar: a lowercase letter, then lowercase letters/digits/`-`/`_`.
    private static let idRegex: NSRegularExpression = {
        // Safe to force-unwrap: the pattern is a fixed, valid literal.
        try! NSRegularExpression(pattern: "^[a-z][a-z0-9_-]*$")
    }()

    private static func isValidId(_ id: String) -> Bool {
        let range = NSRange(id.startIndex..., in: id)
        return idRegex.firstMatch(in: id, range: range) != nil
    }

    package static func parse(yaml: String) throws -> [EventNotificationDefinition] {
        guard let root = try Yams.compose(yaml: yaml), let mapping = root.mapping else {
            return []
        }

        var definitions: [EventNotificationDefinition] = []

        for (keyNode, valueNode) in mapping {
            let eventName = keyNode.string ?? ""
            try IdentifierValidation.validate(eventName, kind: .eventName)
            let eventMapping = valueNode.mapping

            let notificationsSequence = eventMapping?["notifications"]?.sequence ?? []
            guard !notificationsSequence.isEmpty else {
                throw NotificationParseError.emptyNotifications(event: eventName)
            }

            var notifications: [NotificationEntry] = []
            var seenTypes: Set<String> = []
            var seenIds: Set<String> = []
            for entryNode in notificationsSequence {
                let entryMapping = entryNode.mapping
                let type = entryMapping?["type"]?.string ?? ""

                guard let schemaFields = Self.typeSchemas[type] else {
                    throw NotificationParseError.unknownType(event: eventName, type: type)
                }
                guard seenTypes.insert(type).inserted else {
                    throw NotificationParseError.duplicateType(event: eventName, type: type)
                }

                let id = entryMapping?["id"]?.string ?? ""
                guard !id.isEmpty else {
                    throw NotificationParseError.missingId(event: eventName, type: type)
                }
                guard Self.isValidId(id) else {
                    throw NotificationParseError.invalidId(event: eventName, id: id)
                }
                guard seenIds.insert(id).inserted else {
                    throw NotificationParseError.duplicateId(event: eventName, id: id)
                }

                let allowedKeys = Set(schemaFields).union(["type", "render", "id"])
                if let entryMapping {
                    for (fieldKeyNode, _) in entryMapping {
                        guard let fieldKey = fieldKeyNode.string else { continue }
                        guard allowedKeys.contains(fieldKey) else {
                            throw NotificationParseError.extraField(event: eventName, type: type, field: fieldKey)
                        }
                    }
                }

                let render: NotificationRenderFormat
                if let renderValue = entryMapping?["render"]?.string {
                    guard let parsed = NotificationRenderFormat(rawValue: renderValue) else {
                        throw NotificationParseError.invalidRenderFormat(event: eventName, type: type, value: renderValue)
                    }
                    render = parsed
                } else {
                    render = NotificationRenderFormat.defaultFormat(forType: type)
                }

                var fields: [(name: String, template: String)] = []
                for fieldName in schemaFields {
                    guard let template = entryMapping?[fieldName]?.string else {
                        throw NotificationParseError.missingField(event: eventName, type: type, field: fieldName)
                    }
                    fields.append((name: fieldName, template: template))
                }

                notifications.append(NotificationEntry(id: id, type: type, render: render, fields: fields))
            }

            definitions.append(EventNotificationDefinition(eventName: eventName, notifications: notifications))
        }

        return definitions
    }
}
```

`PlaceholderExtractor` (later in the same file) is unchanged — leave it exactly as-is.

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter NotificationParsingTests`
Expected: PASS (23 tests: 15 in `NotificationParsingTests`, 5 in `NotificationRenderParsingTests`,
4 in `PlaceholderExtractorTests` — wait, re-count from the file above and confirm the actual
number; the point is every test in the replaced file passes, none skipped).

- [ ] **Step 7: Run the full DomainEventGenerator test target**

Run: `swift test --filter DomainEventGeneratorTests`
Expected: This will currently FAIL TO COMPILE — `NotificationGenerator.swift` and
`NotificationGeneratorTests.swift` still reference `NotificationEntry.recipients`, which no longer
exists. **This is expected** — Task 2 fixes it. Confirm the compile error is confined to those two
files (nothing else references the removed `.recipients`/`.recipient` symbols) before moving on.

- [ ] **Step 8: Commit**

```bash
git add Sources/DomainEventGenerator/Generator/Notification/NotificationDefinitionFile.swift Sources/DomainEventGenerator/Generator/Notification/IdentifierValidation.swift Tests/DomainEventGeneratorTests/NotificationParsingTests.swift
git commit -m "feat: notification.yaml requires id:, removes recipients:"
```

---

### Task 2: `NotificationGenerator` — per-entry protocol codegen

**Files:**
- Modify: `Package.swift` (add `DDDCore` dependency to `NotificationDefinition` target)
- Modify: `Sources/DomainEventGenerator/Generator/Notification/NotificationGenerator.swift`
- Modify: `Sources/DomainEventGenerator/Generator/Notification/IdentifierValidation.swift`
  (reserve 3 new fixed member names)
- Test: `Tests/DomainEventGeneratorTests/NotificationGeneratorTests.swift`

**Interfaces:**
- Consumes: `NotificationEntry.id` (Task 1); `VariableDefinition`/`VariablesProtocolGenerator`'s
  `__value(of:inputs:)` seam (unchanged, pre-existing).
- Produces: for each `(event, entry)` pair, a generated protocol named
  `\(event.eventName)Notification\(idPascal)Protocol` plus an `extension` providing its default
  `render(variables:)` — this is what Task 3's demo target and any future consumer conforms to.

- [ ] **Step 1: Add `DDDCore` as a dependency of the `NotificationDefinition` target**

The generated protocol will declare `associatedtype DomainEventType: DomainEvent` and emit
`import DDDCore` — `NotificationDefinition` (the runtime support library the generated code
imports) needs to depend on `DDDCore` for this to resolve. In `Package.swift`, find:

```swift
        .target(
            name: "NotificationDefinition",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown")
            ]),
```

change to:

```swift
        .target(
            name: "NotificationDefinition",
            dependencies: [
                "DDDCore",
                .product(name: "Markdown", package: "swift-markdown")
            ]),
```

Then find the `NotificationDefinitionDemo` target (it directly imports `DDDCore` too, in Task 3's
new domain-event file):

```swift
        .target(
            name: "NotificationDefinitionDemo",
            dependencies: [
                "NotificationDefinition",
            ],
            path: "Sources/NotificationDefinitionDemo",
```

change to:

```swift
        .target(
            name: "NotificationDefinitionDemo",
            dependencies: [
                "NotificationDefinition",
                "DDDCore",
            ],
            path: "Sources/NotificationDefinitionDemo",
```

Run `swift build --target NotificationDefinitionDemo` to confirm the package still resolves and
builds (it will build the *existing*, pre-Task-2 generated code — this step is purely dependency
wiring, no behavior change yet).

- [ ] **Step 2: Reserve the 3 new fixed protocol member names**

The generated protocol always declares `event`, `recipients`, and `render` as member names
(alongside the existing `inputs`/`values` local names `render()`'s body declares). A
`variables.yaml` input happening to be named `event`, `recipients`, or `render` would now collide
with the generator's own emitted members. In
`Sources/DomainEventGenerator/Generator/Notification/IdentifierValidation.swift`, change:

```swift
    package static let reservedIdentifiers: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import",
        "init", "inout", "internal", "let", "open", "operator", "private", "protocol", "public",
        "rethrows", "static", "struct", "subscript", "typealias", "var",
        "break", "case", "continue", "default", "defer", "do", "else", "fallthrough", "for", "guard",
        "if", "in", "repeat", "return", "switch", "where", "while",
        "as", "Any", "catch", "false", "is", "nil", "self", "Self", "super", "throw", "throws", "true", "try",
        "_",
        "inputs", "values",
    ]
```

to:

```swift
    package static let reservedIdentifiers: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import",
        "init", "inout", "internal", "let", "open", "operator", "private", "protocol", "public",
        "rethrows", "static", "struct", "subscript", "typealias", "var",
        "break", "case", "continue", "default", "defer", "do", "else", "fallthrough", "for", "guard",
        "if", "in", "repeat", "return", "switch", "where", "while",
        "as", "Any", "catch", "false", "is", "nil", "self", "Self", "super", "throw", "throws", "true", "try",
        "_",
        "inputs", "values",
        // Fixed member names every generated per-entry notification protocol declares
        // (NotificationGenerator) — a variable input named one of these would collide.
        "event", "recipients", "render",
    ]
```

- [ ] **Step 3: Write the failing generator tests**

Replace the entire contents of `Tests/DomainEventGeneratorTests/NotificationGeneratorTests.swift`
with:

```swift
import Testing
@testable import DomainEventGenerator

@Suite("NotificationGenerator")
struct NotificationGeneratorTests {

    static let variables: [VariableDefinition] = [
        VariableDefinition(
            name: "QuotingCaseGroupName",
            placeholder: "QuotingCaseGroupName",
            inputs: [(name: "quotingCaseGroupingId", type: "String")]
        ),
        VariableDefinition(
            name: "QuotingCaseGroupCollaboratorRole",
            placeholder: "QuotingCaseGroupCollaboratorRole",
            inputs: [(name: "quotingCaseGroupingId", type: "String"), (name: "collaboratorId", type: "String")]
        ),
        VariableDefinition(
            name: "CollaboratorDescription",
            placeholder: "CollaboratorDescription",
            inputs: [(name: "quotingCaseGroupingId", type: "String"), (name: "collaboratorId", type: "String")]
        ),
    ]

    static let collaboratorAddedEvent = EventNotificationDefinition(
        eventName: "CollaboratorAdded",
        notifications: [
            NotificationEntry(
                id: "collaborator-added-mail", type: "mail", render: .markdown,
                fields: [
                    (name: "subject", template: "你已被加入案件「%QuotingCaseGroupName%」"),
                    (name: "content", template: "你以「%QuotingCaseGroupCollaboratorRole%」角色被加入案件「%QuotingCaseGroupName%」，%CollaboratorDescription%。"),
                ]),
            NotificationEntry(
                id: "collaborator-added-in-app", type: "inApp", render: .markdown,
                fields: [
                    (name: "title", template: "你已被加入案件「%QuotingCaseGroupName%」"),
                    (name: "content", template: "你以「%QuotingCaseGroupCollaboratorRole%」角色被加入案件「%QuotingCaseGroupName%」。"),
                ]),
        ]
    )

    @Test("emits import DDDCore, Foundation, NotificationDefinition")
    func emitsRequiredImports() throws {
        let generator = NotificationGenerator(
            protocolName: "OpportunityNotificationVariables",
            events: [Self.collaboratorAddedEvent],
            variables: Self.variables
        )
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")
        #expect(output.contains("import DDDCore"))
        #expect(output.contains("import Foundation"))
        #expect(output.contains("import NotificationDefinition"))
    }

    @Test("generates one protocol per entry, named <EventName>Notification<IdPascal>Protocol")
    func protocolNamedFromEventAndId() throws {
        let generator = NotificationGenerator(
            protocolName: "OpportunityNotificationVariables",
            events: [Self.collaboratorAddedEvent],
            variables: Self.variables
        )
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(output.contains("internal protocol CollaboratorAddedNotificationCollaborator_Added_MailProtocol: Sendable {"))
        #expect(output.contains("internal protocol CollaboratorAddedNotificationCollaborator_Added_In_AppProtocol: Sendable {"))
    }

    @Test("id → PascalCase: single segment, and mixed - / _ separators")
    func idPascalCaseTransform() throws {
        let event = EventNotificationDefinition(
            eventName: "Foo",
            notifications: [
                NotificationEntry(id: "mail", type: "mail", render: .markdown, fields: [(name: "subject", template: "hi"), (name: "content", template: "hi")]),
            ])
        let generator = NotificationGenerator(protocolName: "P", events: [event], variables: [])
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")
        #expect(output.contains("protocol FooNotificationMailProtocol: Sendable {"))

        let event2 = EventNotificationDefinition(
            eventName: "Foo",
            notifications: [
                NotificationEntry(id: "test_abc-mail", type: "mail", render: .markdown, fields: [(name: "subject", template: "hi"), (name: "content", template: "hi")]),
            ])
        let generator2 = NotificationGenerator(protocolName: "P", events: [event2], variables: [])
        let output2 = try generator2.render(accessLevel: .internal).joined(separator: "\n")
        #expect(output2.contains("protocol FooNotificationTest_Abc_MailProtocol: Sendable {"))
    }

    @Test("protocol declares associatedtype DomainEventType, var event, known fields, recipients() and render() requirements")
    func protocolDeclaresAllRequirements() throws {
        let generator = NotificationGenerator(
            protocolName: "OpportunityNotificationVariables",
            events: [Self.collaboratorAddedEvent],
            variables: Self.variables
        )
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(output.contains("internal protocol CollaboratorAddedNotificationCollaborator_Added_MailProtocol: Sendable {\n    associatedtype DomainEventType: DomainEvent\n    var event: DomainEventType { get }"))
        // known fields: union of QuotingCaseGroupName/QuotingCaseGroupCollaboratorRole/CollaboratorDescription's
        // inputs, referenced by the mail entry's own subject/content templates.
        #expect(output.contains("var collaboratorId: String { get }"))
        #expect(output.contains("var quotingCaseGroupingId: String { get }"))
        #expect(output.contains("func recipients() async throws -> [String]"))
        #expect(output.contains("func render(variables: some OpportunityNotificationVariables) async throws -> RenderedNotification"))
    }

    @Test("known-field properties are derived per entry, not shared across the event's other entries")
    func knownFieldsArePerEntry() throws {
        // mail's content uses CollaboratorDescription (needs collaboratorId); inApp's content
        // does not — so inApp's protocol must NOT declare a collaboratorId property, even though
        // it's declared for mail (same event).
        let event = EventNotificationDefinition(
            eventName: "CollaboratorAdded",
            notifications: [
                NotificationEntry(
                    id: "mail-with-description", type: "mail", render: .markdown,
                    fields: [
                        (name: "subject", template: "hi"),
                        (name: "content", template: "%CollaboratorDescription%"),
                    ]),
                NotificationEntry(
                    id: "in-app-plain", type: "inApp", render: .plaintext,
                    fields: [
                        (name: "title", template: "hi"),
                        (name: "content", template: "%QuotingCaseGroupName%"),
                    ]),
            ])
        let generator = NotificationGenerator(protocolName: "P", events: [event], variables: Self.variables)
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        let mailProtocolStart = try #require(output.range(of: "protocol CollaboratorAddedNotificationMail_With_DescriptionProtocol"))
        let inAppProtocolStart = try #require(output.range(of: "protocol CollaboratorAddedNotificationIn_App_PlainProtocol"))
        let mailBlock = String(output[mailProtocolStart.lowerBound..<inAppProtocolStart.lowerBound])

        #expect(mailBlock.contains("var collaboratorId: String { get }"))
        #expect(mailBlock.contains("var quotingCaseGroupingId: String { get }"))

        let inAppBlock = String(output[inAppProtocolStart.lowerBound...])
        #expect(!inAppBlock.contains("var collaboratorId: String { get }"))
        #expect(inAppBlock.contains("var quotingCaseGroupingId: String { get }"))
    }

    @Test("an entry with no placeholders has no known-field properties and no inputs/values dicts")
    func entryWithNoPlaceholdersHasNoKnownFields() throws {
        let event = EventNotificationDefinition(
            eventName: "Foo",
            notifications: [
                NotificationEntry(id: "static-mail", type: "mail", render: .plaintext, fields: [(name: "subject", template: "hi"), (name: "content", template: "static text, no tokens")]),
            ])
        let generator = NotificationGenerator(protocolName: "P", events: [event], variables: [])
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        // Exactly one " { get }" in the whole output — the fixed `var event: DomainEventType { get }`
        // — proves no known-field property line was added.
        #expect(output.components(separatedBy: "{ get }").count - 1 == 1)
        #expect(!output.contains("let inputs: [String: String] = ["))
        #expect(!output.contains("let values: [String: String] = ["))
    }

    @Test("default render() extension resolves placeholders and calls self.recipients()")
    func defaultRenderCallsRecipientsAndSubstitutes() throws {
        let event = EventNotificationDefinition(
            eventName: "Foo",
            notifications: [
                NotificationEntry(id: "mail", type: "mail", render: .markdown, fields: [(name: "subject", template: "hi %QuotingCaseGroupName%"), (name: "content", template: "body")]),
            ])
        let generator = NotificationGenerator(protocolName: "P", events: [event], variables: [Self.variables[0]])
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(output.contains("extension FooNotificationMailProtocol {"))
        #expect(output.contains("let inputs: [String: String] = ["))
        #expect(output.contains("\"quotingCaseGroupingId\": quotingCaseGroupingId,"))
        #expect(output.contains("let quotingCaseGroupName = try await variables.__value(of: \"QuotingCaseGroupName\", inputs: inputs)"))
        #expect(output.contains("recipients: try await self.recipients(),"))
        #expect(output.contains("type: NotificationType(rawValue: \"mail\")!,"))
    }

    @Test("inApp entries carry the render wire field, mail entries do not")
    func inAppCarriesRenderField() throws {
        let generator = NotificationGenerator(
            protocolName: "OpportunityNotificationVariables",
            events: [Self.collaboratorAddedEvent],
            variables: Self.variables
        )
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        let mailStart = try #require(output.range(of: "extension CollaboratorAddedNotificationCollaborator_Added_MailProtocol"))
        let inAppStart = try #require(output.range(of: "extension CollaboratorAddedNotificationCollaborator_Added_In_AppProtocol"))
        let mailBlock = String(output[mailStart.lowerBound..<inAppStart.lowerBound])
        let inAppBlock = String(output[inAppStart.lowerBound...])

        #expect(!mailBlock.contains("\"render\":"))
        #expect(inAppBlock.contains("\"render\": \"markdown\","))
    }

    @Test("markdown content is rendered via MarkdownRendering.html, plaintext content is not")
    func markdownVsPlaintextContentRendering() throws {
        let event = EventNotificationDefinition(
            eventName: "Foo",
            notifications: [
                NotificationEntry(id: "md-mail", type: "mail", render: .markdown, fields: [(name: "subject", template: "hi"), (name: "content", template: "body")]),
                NotificationEntry(id: "plain-in-app", type: "inApp", render: .plaintext, fields: [(name: "title", template: "hi"), (name: "content", template: "body")]),
            ])
        let generator = NotificationGenerator(protocolName: "P", events: [event], variables: [])
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(output.contains("\"content\": MarkdownRendering.html(from: try PlaceholderSubstitution.substitute(\"body\", values: [:], escaping: .markdown)),"))
        #expect(output.contains("\"content\": try PlaceholderSubstitution.substitute(\"body\", values: [:]),"))
    }

    @Test("undefined placeholder throws undefinedPlaceholder")
    func undefinedPlaceholderThrows() {
        let event = EventNotificationDefinition(
            eventName: "Foo",
            notifications: [
                NotificationEntry(id: "mail", type: "mail", render: .markdown, fields: [(name: "subject", template: "%NoSuchVariable%"), (name: "content", template: "hi")]),
            ])
        let generator = NotificationGenerator(protocolName: "P", events: [event], variables: [])
        #expect(throws: NotificationGenerateError.undefinedPlaceholder(event: "Foo", placeholder: "NoSuchVariable")) {
            _ = try generator.render(accessLevel: .internal)
        }
    }

    @Test("two ids producing the same generated protocol name throw duplicateGeneratedProtocolName")
    func duplicateGeneratedProtocolNameThrows() {
        let event = EventNotificationDefinition(
            eventName: "Foo",
            notifications: [
                NotificationEntry(id: "test-abc", type: "mail", render: .markdown, fields: [(name: "subject", template: "hi"), (name: "content", template: "hi")]),
                NotificationEntry(id: "test_abc", type: "inApp", render: .markdown, fields: [(name: "title", template: "hi"), (name: "content", template: "hi")]),
            ])
        let generator = NotificationGenerator(protocolName: "P", events: [event], variables: [])
        #expect(throws: NotificationGenerateError.duplicateGeneratedProtocolName(event: "Foo", a: "test-abc", b: "test_abc")) {
            _ = try generator.render(accessLevel: .internal)
        }
    }

    @Test("unreferencedVariables still reports a variable no entry's templates reference")
    func unreferencedVariablesUnaffected() {
        let generator = NotificationGenerator(
            protocolName: "OpportunityNotificationVariables",
            events: [Self.collaboratorAddedEvent],
            variables: Self.variables + [
                VariableDefinition(name: "NeverUsed", placeholder: "NeverUsed", inputs: []),
            ]
        )
        #expect(generator.unreferencedVariables == ["NeverUsed"])
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `swift test --filter NotificationGeneratorTests`
Expected: FAIL to compile — `NotificationEntry(id:type:render:fields:)` doesn't match the old
generator's expectations, `NotificationGenerateError.duplicateGeneratedProtocolName` doesn't
exist, and the generated output doesn't match any of the new assertions.

- [ ] **Step 5: Rewrite `NotificationGenerator.swift`**

Replace the entire contents of
`Sources/DomainEventGenerator/Generator/Notification/NotificationGenerator.swift` with:

```swift
//
//  NotificationGenerator.swift
//  DomainEventGenerator
//
//  For each (event, notification entry) pair declared in `notification.yaml`, generates a
//  protocol the consumer implements — exposing the real `DomainEvent`, the entry's own known
//  text-template fields, a `recipients()` requirement, and an overridable `render()` — plus an
//  extension providing `render()`'s default implementation. Cross-validated against
//  `variables.yaml`. Consumes the `__value(of:inputs:)` seam emitted by
//  `VariablesProtocolGenerator` verbatim.
//  See spec: docs/superpowers/specs/2026-09-19-per-entry-notification-recipients-protocol-design.md
//

import Foundation

package enum NotificationGenerateError: Error, Equatable, Sendable {
    case undefinedPlaceholder(event: String, placeholder: String)
    /// Two entries in the same event have different `id`s that transform to the same
    /// PascalCase-with-underscore name (e.g. `test-abc` and `test_abc` both become `Test_Abc`),
    /// which would otherwise silently collide as the same generated protocol name.
    case duplicateGeneratedProtocolName(event: String, a: String, b: String)
}

extension NotificationGenerateError: CustomStringConvertible {
    package var description: String {
        switch self {
        case .undefinedPlaceholder(let event, let placeholder):
            return "event '\(event)': placeholder '%\(placeholder)%' has no matching variable in variables.yaml"
        case .duplicateGeneratedProtocolName(let event, let a, let b):
            return "event '\(event)': ids '\(a)' and '\(b)' both produce the same generated protocol name — rename one"
        }
    }
}

package struct NotificationGenerator {
    let protocolName: String
    let events: [EventNotificationDefinition]
    let variables: [VariableDefinition]

    package init(protocolName: String, events: [EventNotificationDefinition], variables: [VariableDefinition]) {
        self.protocolName = protocolName
        self.events = events
        self.variables = variables
    }

    /// Variables defined in `variables.yaml` but never referenced by any event's templates.
    /// Not part of the generated code — the CLI layer prints these as `warning:` lines.
    package var unreferencedVariables: [String] {
        var referencedPlaceholders: Set<String> = []
        for event in events {
            for entry in event.notifications {
                for field in entry.fields {
                    referencedPlaceholders.formUnion(PlaceholderExtractor.placeholders(in: field.template))
                }
            }
        }
        return variables
            .filter { !referencedPlaceholders.contains($0.placeholder) }
            .map { $0.name }
            .sorted()
    }

    package func render(accessLevel: AccessLevel) throws -> [String] {
        let access = accessLevel.rawValue
        let variablesByPlaceholder = Dictionary(uniqueKeysWithValues: variables.map { ($0.placeholder, $0) })
        let sortedEvents = events.sorted { $0.eventName < $1.eventName }

        var lines: [String] = ["import DDDCore", "import Foundation", "import NotificationDefinition"]

        for event in sortedEvents {
            // Detect two ids in this event that would produce the same generated protocol name
            // before emitting anything for this event.
            var idPascalToId: [String: String] = [:]
            for entry in event.notifications {
                let idPascal = Self.idPascalCase(entry.id)
                if let existingId = idPascalToId[idPascal], existingId != entry.id {
                    throw NotificationGenerateError.duplicateGeneratedProtocolName(
                        event: event.eventName, a: existingId, b: entry.id)
                }
                idPascalToId[idPascal] = entry.id
            }

            for entry in event.notifications {
                lines.append(
                    try Self.renderEntry(
                        access: access,
                        protocolName: protocolName,
                        event: event,
                        entry: entry,
                        variablesByPlaceholder: variablesByPlaceholder))
            }
        }

        return lines
    }

    /// Renders one entry's generated protocol + default-implementation extension.
    private static func renderEntry(
        access: String,
        protocolName: String,
        event: EventNotificationDefinition,
        entry: NotificationEntry,
        variablesByPlaceholder: [String: VariableDefinition]
    ) throws -> String {
        // Distinct placeholders referenced by THIS ENTRY's own fields (not the whole event), in
        // first-appearance order — order only matters for validation; declaration order in the
        // generated code is alphabetical for determinism (see sortedPlaceholders below).
        var orderedPlaceholders: [String] = []
        var seenPlaceholders: Set<String> = []
        for field in entry.fields {
            for placeholder in PlaceholderExtractor.placeholders(in: field.template) {
                if seenPlaceholders.insert(placeholder).inserted {
                    orderedPlaceholders.append(placeholder)
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
        for variable in matchedVariables {
            for input in variable.inputs {
                propertyNames.insert(input.name)
            }
        }
        let sortedProperties = propertyNames.sorted()

        let idPascal = Self.idPascalCase(entry.id)
        let protocolTypeName = "\(event.eventName)Notification\(idPascal)Protocol"

        return Self.renderProtocolAndExtension(
            access: access,
            protocolName: protocolName,
            protocolTypeName: protocolTypeName,
            entry: entry,
            properties: sortedProperties,
            placeholders: sortedPlaceholders
        )
    }

    /// `test-abc-mail` -> `Test_Abc_Mail`: split on `-`/`_`, uppercase each segment's first
    /// letter, rejoin with `_`.
    private static func idPascalCase(_ id: String) -> String {
        id.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { segment -> String in
                guard let first = segment.first else { return String(segment) }
                return first.uppercased() + segment.dropFirst()
            }
            .joined(separator: "_")
    }

    private static func renderProtocolAndExtension(
        access: String,
        protocolName: String,
        protocolTypeName: String,
        entry: NotificationEntry,
        properties: [String],
        placeholders: [String]
    ) -> String {
        var lines: [String] = []

        // 1. The protocol.
        lines.append("\(access) protocol \(protocolTypeName): Sendable {")
        lines.append("    associatedtype DomainEventType: DomainEvent")
        lines.append("    var event: DomainEventType { get }")
        lines.append("")
        for property in properties {
            lines.append("    var \(property): String { get }")
        }
        if !properties.isEmpty { lines.append("") }
        lines.append("    func recipients() async throws -> [String]")
        lines.append("    func render(variables: some \(protocolName)) async throws -> RenderedNotification")
        lines.append("}")
        lines.append("")

        // 2. Default render() implementation.
        lines.append("extension \(protocolTypeName) {")
        lines.append("    \(access) func render(variables: some \(protocolName)) async throws -> RenderedNotification {")

        if !placeholders.isEmpty {
            lines.append("        let inputs: [String: String] = [")
            for property in properties {
                lines.append("            \"\(property)\": \(property),")
            }
            lines.append("        ]")
        }

        for placeholder in placeholders {
            let letName = Self.lowerCamel(placeholder)
            lines.append("        let \(letName) = try await variables.__value(of: \"\(placeholder)\", inputs: inputs)")
        }

        if !placeholders.isEmpty {
            lines.append("        let values: [String: String] = [")
            for placeholder in placeholders {
                lines.append("            \"\(placeholder)\": \(Self.lowerCamel(placeholder)),")
            }
            lines.append("        ]")
        }

        lines.append("        return RenderedNotification(")
        lines.append("            type: NotificationType(rawValue: \"\(entry.type)\")!,")
        lines.append("            recipients: try await self.recipients(),")
        lines.append("            fields: [")
        for field in entry.fields {
            let escapedTemplate = Self.escapeSwiftStringLiteral(field.template)
            let valuesArgument = placeholders.isEmpty ? "[:]" : "values"
            // `content` fields' handling depends on the entry's resolved `render` value — see
            // docs/superpowers/specs/2026-09-09-markdown-notification-content-design.md §3-4 and
            // docs/superpowers/specs/2026-09-15-inapp-render-format-design.md §3.
            if field.name == "content", entry.render == .markdown {
                lines.append(
                    "                \"\(field.name)\": MarkdownRendering.html(from: try PlaceholderSubstitution.substitute(\"\(escapedTemplate)\", values: \(valuesArgument), escaping: .markdown)),"
                )
            } else {
                lines.append(
                    "                \"\(field.name)\": try PlaceholderSubstitution.substitute(\"\(escapedTemplate)\", values: \(valuesArgument)),"
                )
            }
        }
        if entry.type == "inApp" {
            // Wire model: inApp carries its resolved render format alongside title/content
            // (mail's render choice is fully resolved into HTML upstream, so mail never gets
            // this field).
            lines.append("                \"render\": \"\(entry.render.rawValue)\",")
        }
        lines.append("            ])")
        lines.append("    }")
        lines.append("}")

        return lines.joined(separator: "\n")
    }

    private static func lowerCamel(_ name: String) -> String {
        guard let first = name.first else { return name }
        return first.lowercased() + name.dropFirst()
    }

    private static func escapeSwiftStringLiteral(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return escaped
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter NotificationGeneratorTests`
Expected: PASS (13 tests).

- [ ] **Step 7: Run the full DomainEventGenerator test target**

Run: `swift test --filter DomainEventGeneratorTests`
Expected: PASS — this now includes Task 1's `NotificationParsingTests`, unaffected
`VariablesParsingTests`/`VariablesProtocolGeneratorTests`, and this task's
`NotificationGeneratorTests`.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/DomainEventGenerator/Generator/Notification/NotificationGenerator.swift Sources/DomainEventGenerator/Generator/Notification/IdentifierValidation.swift Tests/DomainEventGeneratorTests/NotificationGeneratorTests.swift
git commit -m "feat: NotificationGenerator emits a per-entry protocol instead of a shared Input struct"
```

---

### Task 3: Demo target + README

**Files:**
- Modify: `Sources/NotificationDefinitionDemo/notification.yaml`
- Create: `Sources/NotificationDefinitionDemo/DemoDomainEvent.swift`
- Create: `Sources/NotificationDefinitionDemo/CollaboratorAddedNotifications.swift`
- Modify: `Tests/NotificationDefinitionDemoTests/DemoRenderTests.swift`
- Modify: `README.md` (the `notification.yaml` section, lines 726-791 in the pre-Task-3 file)

**Interfaces:**
- Consumes: `CollaboratorAddedNotificationCollaborator_Added_MailProtocol` and
  `CollaboratorAddedNotificationCollaborator_Added_In_AppProtocol` (Task 2's generator output for
  the demo's `notification.yaml`, once this task's Step 1 gives those entries the ids
  `collaborator-added-mail`/`collaborator-added-in-app`).

- [ ] **Step 1: Update the demo's `notification.yaml`**

Replace the entire contents of `Sources/NotificationDefinitionDemo/notification.yaml` with:

```yaml
CollaboratorAdded:
  notifications:
    - id: collaborator-added-mail
      type: mail
      subject: 你已被加入案件「%QuotingCaseGroupName%」
      content: |
        你以「%QuotingCaseGroupCollaboratorRole%」角色被加入案件「%QuotingCaseGroupName%」，%CollaboratorDescription%。
    - id: collaborator-added-in-app
      type: inApp
      title: 你已被加入案件「%QuotingCaseGroupName%」
      content: 你以「%QuotingCaseGroupCollaboratorRole%」角色被加入案件「%QuotingCaseGroupName%」。
```

(`Sources/NotificationDefinitionDemo/variables.yaml` and `DemoVariables.swift` are unchanged —
the environment-variable mechanism is untouched by this plan.)

- [ ] **Step 2: Write the demo's hand-written `DomainEvent`-conforming type**

Create `Sources/NotificationDefinitionDemo/DemoDomainEvent.swift`:

```swift
//
//  DemoDomainEvent.swift
//  NotificationDefinitionDemo
//
//  A minimal hand-written `DomainEvent` conformance — proves the generated per-entry
//  notification protocols work against a REAL domain event, not a synthesized flat struct. Real
//  contexts generate their events via `DomainEventGenerator`'s `event.yaml` DSL; this demo
//  hand-writes one instead, to avoid pulling that second codegen pipeline into this demo target.
//

import DDDCore
import Foundation

public struct DemoMetadata: Codable, Sendable {
    public let operatorId: String
    public init(operatorId: String) {
        self.operatorId = operatorId
    }
}

public struct CollaboratorAddedEvent: DomainEvent {
    public typealias Metadata = DemoMetadata

    public let id: UUID
    public let collaboratorId: String
    public let quotingCaseGroupingId: String
    public var metadata: Metadata?
    public let aggregateRootId: String
    public let occurred: Date

    public init(
        id: UUID = UUID(),
        collaboratorId: String,
        quotingCaseGroupingId: String,
        metadata: Metadata? = nil,
        aggregateRootId: String,
        occurred: Date = .now
    ) {
        self.id = id
        self.collaboratorId = collaboratorId
        self.quotingCaseGroupingId = quotingCaseGroupingId
        self.metadata = metadata
        self.aggregateRootId = aggregateRootId
        self.occurred = occurred
    }
}
```

- [ ] **Step 3: Run a build to see the generated protocol names**

Run: `swift build --target NotificationDefinitionDemo 2>&1 | tail -30`
Expected: build FAILS — `Sources/NotificationDefinitionDemo` has no type conforming to
`CollaboratorAddedNotificationCollaborator_Added_MailProtocol`/
`CollaboratorAddedNotificationCollaborator_Added_In_AppProtocol` yet, but the generator plugin
itself succeeds. Locate the generated file to confirm the exact protocol names it produced:

```bash
find .build -path "*NotificationGeneratorPlugin/generated/generated-notification.swift" | head -1 | xargs cat
```

Confirm the two protocol names match `CollaboratorAddedNotificationCollaborator_Added_MailProtocol`
and `CollaboratorAddedNotificationCollaborator_Added_In_AppProtocol` (from `collaborator-added-mail`
→ `Collaborator_Added_Mail`, `collaborator-added-in-app` → `Collaborator_Added_In_App`) before
writing Step 4 — if Task 2's `idPascalCase` transform produced something different, use the actual
generated name instead of guessing.

- [ ] **Step 4: Write the conforming types**

Create `Sources/NotificationDefinitionDemo/CollaboratorAddedNotifications.swift`:

```swift
//
//  CollaboratorAddedNotifications.swift
//  NotificationDefinitionDemo
//
//  Hand-written conformers to the GENERATED per-entry protocols (from notification.yaml's
//  `collaborator-added-mail`/`collaborator-added-in-app` entries, produced by
//  NotificationGeneratorPlugin). The mail conformer doesn't override `render()` (exercises the
//  protocol extension's default implementation); the inApp conformer DOES override it, proving a
//  conformer's own `render(variables:)` is correctly selected over the extension's default —
//  which would NOT happen if `render` were declared only in the extension, not as a protocol
//  requirement.
//

import NotificationDefinition

public struct CollaboratorAddedMailNotification: CollaboratorAddedNotificationCollaborator_Added_MailProtocol {
    public let event: CollaboratorAddedEvent
    public var quotingCaseGroupingId: String { event.quotingCaseGroupingId }
    public var collaboratorId: String { event.collaboratorId }

    public init(event: CollaboratorAddedEvent) {
        self.event = event
    }

    public func recipients() async throws -> [String] {
        [event.collaboratorId]
    }
}

public struct CollaboratorAddedInAppNotification: CollaboratorAddedNotificationCollaborator_Added_In_AppProtocol {
    public let event: CollaboratorAddedEvent
    public var quotingCaseGroupingId: String { event.quotingCaseGroupingId }
    public var collaboratorId: String { event.collaboratorId }

    public init(event: CollaboratorAddedEvent) {
        self.event = event
    }

    public func recipients() async throws -> [String] {
        [event.collaboratorId]
    }

    public func render(variables: some DemoNotificationVariables) async throws -> RenderedNotification {
        RenderedNotification(
            type: .inApp,
            recipients: try await self.recipients(),
            fields: ["title": "OVERRIDDEN", "content": "OVERRIDDEN", "render": "plaintext"])
    }
}
```

(If Step 3 found different generated protocol names, use those exact names in the two `: <Name>`
conformance clauses above instead.)

- [ ] **Step 5: Rewrite the demo's render tests**

Replace the entire contents of `Tests/NotificationDefinitionDemoTests/DemoRenderTests.swift` with:

```swift
//
//  DemoRenderTests.swift
//  NotificationDefinitionDemoTests
//
//  Exercises the generated per-entry protocols (produced by NotificationGeneratorPlugin from
//  Sources/NotificationDefinitionDemo's yamls) against a real `DomainEvent`-conforming type,
//  using the hand-written `DemoVariables` stub for the environment-variable protocol. This is the
//  end-to-end proof that the notification-definition codegen chain compiles AND behaves for the
//  new per-entry-protocol design.
//

import Foundation
import Testing

@testable import NotificationDefinitionDemo
import NotificationDefinition

@Suite("DemoRender")
struct DemoRenderTests {

    private func makeEvent(
        collaboratorId: String = "collaborator-1", quotingCaseGroupingId: String = "case-1"
    ) -> CollaboratorAddedEvent {
        CollaboratorAddedEvent(
            collaboratorId: collaboratorId,
            quotingCaseGroupingId: quotingCaseGroupingId,
            aggregateRootId: quotingCaseGroupingId)
    }

    @Test func mailUsesDefaultRenderAndSubstitutesFieldsExactly() async throws {
        let notification = CollaboratorAddedMailNotification(event: makeEvent())
        let rendered = try await notification.render(variables: DemoVariables())

        #expect(rendered.type == .mail)
        #expect(rendered.recipients == ["collaborator-1"])
        #expect(rendered.fields["subject"] == "你已被加入案件「6666」")
        // The mail `content` field is authored as Markdown (a `content: |` block scalar) and
        // rendered to safe HTML by the generated default `render()` — see
        // docs/superpowers/specs/2026-09-09-markdown-notification-content-design.md §3-4.
        #expect(rendered.fields["content"] == "<p>你以「編輯者」角色被加入案件「6666」，歡迎加入團隊。</p>")
        // mail never carries a `render` wire field.
        #expect(rendered.fields["render"] == nil)
    }

    @Test func inAppOverriddenRenderIsSelectedOverDefault() async throws {
        // Proves render(variables:) being a protocol requirement (not only an extension method)
        // means this conformer's own implementation is what actually runs.
        let notification = CollaboratorAddedInAppNotification(event: makeEvent())
        let rendered = try await notification.render(variables: DemoVariables())

        #expect(rendered.type == .inApp)
        #expect(rendered.fields["title"] == "OVERRIDDEN")
        #expect(rendered.fields["content"] == "OVERRIDDEN")
        #expect(rendered.recipients == ["collaborator-1"])
    }

    @Test func recipientsComeFromTheRealDomainEventField() async throws {
        let notification = CollaboratorAddedMailNotification(event: makeEvent(collaboratorId: "collaborator-42"))
        let rendered = try await notification.render(variables: DemoVariables())
        #expect(rendered.recipients == ["collaborator-42"])
    }

    @Test func metadataIsAccessibleOnTheRealDomainEvent() async throws {
        // Not exercised by CollaboratorAddedMailNotification's recipients() today (it doesn't
        // need metadata), but confirms the real event's `.metadata` — inaccessible in the old
        // Input-struct design — is reachable through `event` on the conforming type.
        var event = makeEvent()
        event.metadata = DemoMetadata(operatorId: "operator-9")
        let notification = CollaboratorAddedMailNotification(event: event)
        #expect(notification.event.metadata?.operatorId == "operator-9")
    }
}
```

- [ ] **Step 6: Run the demo tests**

Run: `swift test --filter NotificationDefinitionDemoTests`
Expected: PASS (4 tests).

- [ ] **Step 7: Update the README**

In `README.md`, find the `### \`notification.yaml\`` section (starts at the line containing
`### \`notification.yaml\``, ends right before `### Wiring both plugins into a target`). Replace
its entire contents (the heading itself through the last code block before the next `###`
heading) with:

```markdown
### `notification.yaml`

Declares, per domain event type, what each channel says: `notifications`, a list of
`{id, type, ...fields}` entries. Each entry gets its own generated protocol — the consumer
implements it directly, providing the real domain event and the recipient logic (mail and inApp
can notify completely different people for the same event, since each is its own protocol). The
type schema is closed: `mail` → `subject` + `content`, `inApp` → `title` + `content`. Every entry
also takes an optional `render: markdown | plaintext` key, defaulting per channel type when
omitted (`mail` → `markdown`, `inApp` → `plaintext`):

```yaml
CollaboratorAdded:
  notifications:
    - id: collaborator-added-mail
      type: mail
      subject: 你已被加入案件「%QuotingCaseGroupName%」
      content: |
        你以「%QuotingCaseGroupCollaboratorRole%」角色被加入案件「%QuotingCaseGroupName%」，%CollaboratorDescription%。
    - id: collaborator-added-in-app
      type: inApp
      title: 你已被加入案件「%QuotingCaseGroupName%」
      content: 你以「%QuotingCaseGroupCollaboratorRole%」角色被加入案件「%QuotingCaseGroupName%」。
```

`id` is required on every entry and must be unique among the entries of the same event (it may
repeat across different events). It must match `^[a-z][a-z0-9_-]*$` — lowercase letters, digits,
`-`, `_`, starting with a letter — and is transformed into the generated protocol's name by
splitting on `-`/`_`, uppercasing each segment's first letter, and rejoining with `_`:
`collaborator-added-mail` → `Collaborator_Added_Mail` → `CollaboratorAddedNotificationCollaborator_Added_MailProtocol`.

Neither entry declares `render:` above, so each gets its channel type's default (`mail` →
`markdown`, `inApp` → `plaintext`). Both directions are legal on both types — e.g. an inApp entry
that wants a link can opt in with `render: markdown`:

```yaml
    - id: some-in-app-entry
      type: inApp
      render: markdown        # override the inApp default
      title: ...
      content: 前往查看：[案件連結](https://mendesky.jwcpas.net/quoting-cases)
```

`render: markdown` parses `content` as Markdown and emits safe allow-listed HTML (escaping
substituted values first, see below). `render: plaintext` skips Markdown parsing entirely and
substitutes `%Placeholder%` values into the literal string with no escaping — there is no markup
context for them to escape into. `subject`/`title` are always plain-substituted regardless of
`render`. An inApp entry's resolved `render` value is also carried on the wire as a `"render"` key
in its `fields` (see `RenderedNotification.payloadEntries` below → `inApp.render`); mail never gets
this field — its render choice is fully resolved into HTML before publishing, so downstream
consumers need no `render` awareness for mail. Full rationale:
[`docs/superpowers/specs/2026-09-15-inapp-render-format-design.md`](docs/superpowers/specs/2026-09-15-inapp-render-format-design.md).

`NotificationGeneratorPlugin` cross-validates every `%Placeholder%` token against `variables.yaml`
(an undefined placeholder is a build error; a defined-but-unreferenced variable is a stderr
warning) and generates, per entry, a protocol you implement directly:

```swift
public protocol CollaboratorAddedNotificationCollaborator_Added_MailProtocol: Sendable {
    associatedtype DomainEventType: DomainEvent
    var event: DomainEventType { get }

    var collaboratorId: String { get }          // known fields: union of this entry's
    var quotingCaseGroupingId: String { get }   // referenced variables' `inputs`

    func recipients() async throws -> [String]                                                  // you implement this
    func render(variables: some OpportunityNotificationVariables) async throws -> RenderedNotification  // has a default; override to customize
}
```

`event`'s type is generic (`associatedtype DomainEventType: DomainEvent`) — your conforming type
supplies the real domain event, giving `recipients()` (and an overridden `render()`) access to any
of its fields, including `event.metadata`, not just the ones `notification.yaml`/`variables.yaml`
happen to reference. `recipients()` has no default implementation — you must provide one. `render`
IS declared as a protocol requirement (not only in an extension) specifically so a conformer's own
`render(variables:)` is correctly selected over the default one via dynamic dispatch; the default
implementation resolves this entry's own text-template placeholders the same way as before and
calls your `recipients()` for the recipient list:

```swift
struct CollaboratorAddedMailNotification: CollaboratorAddedNotificationCollaborator_Added_MailProtocol {
    let event: CollaboratorAddedEvent   // your real domain event type
    var collaboratorId: String { event.collaboratorId }
    var quotingCaseGroupingId: String { event.quotingCaseGroupingId }

    func recipients() async throws -> [String] {
        [event.collaboratorId]
    }
    // render() not overridden — uses the generated default.
}
```
```

- [ ] **Step 8: Run the full package test suite**

Run: `swift test`
Expected: PASS across every target. Confirm no compile errors and no leftover references to the
removed `NotificationEntry.recipients`/`IdentifierKind.recipient`/`NotificationParseError.
emptyRecipients` anywhere in the repo (`grep -rn "emptyRecipients\|IdentifierKind.recipient" Sources Tests` should return nothing).

- [ ] **Step 9: Commit**

```bash
git add Sources/NotificationDefinitionDemo Tests/NotificationDefinitionDemoTests README.md
git commit -m "feat: demo + README for the per-entry notification protocol design"
```

---

## Self-Review Notes (for the plan author, already applied above)

- **Spec coverage:** §2 (revert PR #17 scope) → satisfied by starting fresh off `main`, which never
  had PR #17's changes (Task 1/2 don't need to "revert" anything, they implement the new design
  directly against the pre-PR-17 baseline). §3 (`id:`, `recipients:` removed) → Task 1. §3.1
  (`DomainEvent` reused, no new type) → Task 2 Step 1 (dependency wiring only, no new metadata
  type in swift-ddd-kit itself). §3.2 (per-entry protocol shape, naming, `render()` as requirement)
  → Task 2. §3.3 (known fields derived per entry) → Task 2's `knownFieldsArePerEntry` test. §4
  (usage example) → Task 3's demo. §5 (validation rules) → Task 1 (`missingId`/`invalidId`/
  `duplicateId`) and Task 2 (`duplicateGeneratedProtocolName`). §6 (demo update) → Task 3. §7
  (testing plan) → covered across all three tasks' test steps, including the "override actually
  works" requirement (Task 3's `inAppOverriddenRenderIsSelectedOverDefault`). §8 (migration order,
  OC out of scope) → not part of this plan, correctly. §9 (undecided details) → resolved inline
  where this plan needed to (error case naming, demo's chosen domain event, id charset regex);
  `lowerCamel` dedup left alone (out of scope, no functional bearing).
- **Type consistency:** `NotificationEntry.id` (Task 1) is consumed by name in Task 2's
  `idPascalCase`/`renderEntry`. `NotificationGenerateError.duplicateGeneratedProtocolName` is
  introduced and consumed consistently within Task 2. Task 3's conformance clause names are
  cross-checked against Task 2's exact `idPascalCase` transform (`collaborator-added-mail` →
  `Collaborator_Added_Mail`), with an explicit Step 3 build-and-verify step as a safety net in case
  the transform's actual output differs from this plan's hand-computed expectation.
- **No placeholders:** every step contains complete, concrete code — no "update accordingly" or
  "similar to Task N" placeholders. The one deliberately-open point (Task 3 Step 3's "if the name
  differs, use the actual one") is a verification step, not an unresolved requirement — the exact
  transform is fully specified in Task 2.
