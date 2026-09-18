# Per-Notification-Type Recipients (swift-ddd-kit) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `recipients` from `notification.yaml`'s event level into each `notifications:`
entry, and change `ContextForwarder`'s `ForwardingRule.translate` to return multiple published
events instead of one, so a single domain event can notify different recipients per channel.

**Architecture:** Three independent layers change together: the YAML parser
(`NotificationDefinitionFile.swift`) moves `recipients` down one level; the generator
(`NotificationGenerator.swift`) and the runtime type (`NotificationDefinition.swift`'s
`RenderedNotification`) carry recipients per rendered entry instead of a separate per-event
function; `ContextForwarder`'s core (`ForwardingRule.swift`, `ContextForwarder.swift`) changes
`translate` to return an array, since one record can now legitimately produce several published
events. This plan does NOT touch OC's `OCForwarding.swift` or NotificationContext's ingest — those
are separate, downstream plans (§8 of the spec sequences NC before OC once this lands).

**Tech Stack:** Swift 6, swift-testing (`@Test`/`@Suite`/`#expect`), Yams (YAML parsing).

**Spec:** NotificationContext repo,
`docs/superpowers/specs/2026-09-18-per-notification-type-recipients-design.md` (§2-4 cover this
plan's scope; §5-9 cover NC/OC, out of scope here).

## Global Constraints

- Every existing test in `DomainEventGeneratorTests` and `ContextForwarderTests` must still pass
  (this is a breaking API change to two public types — `EventNotificationDefinition` and
  `ForwardingRule` — so their existing tests need updating, not just new ones added).
- `ForwardingDisposition(forAnyOf:)` (`Tests/ContextForwarderTests/MultiRuleDispositionTests.swift`)
  is untouched by this plan — it operates on `[any Error]`, independent of how many events a
  successful `translate` call produces. Do not modify it or its tests.
- `package` access level throughout `DomainEventGeneratorTests`'s target types
  (`NotificationEntry`, `EventNotificationDefinition`, `NotificationParseError`) — match the
  existing access level exactly, do not widen or narrow it.
- No change to `variables.yaml`, `VariablesProtocolGenerator.swift`, or anything under
  `Sources/DomainEventGenerator/Generator/Notification/IdentifierValidation.swift` — out of scope.

---

### Task 1: Move `recipients` into `NotificationEntry` (parser)

**Files:**
- Modify: `Sources/DomainEventGenerator/Generator/Notification/NotificationDefinitionFile.swift`
- Test: `Tests/DomainEventGeneratorTests/NotificationGeneratorTests.swift` (parser tests currently
  live in this file — search for `NotificationDefinitionParser.parse`)

**Interfaces:**
- Produces: `NotificationEntry` gains `recipients: [String]`. `EventNotificationDefinition` drops
  its `recipients` field entirely (now just `eventName` + `notifications`).
  `NotificationParseError.emptyRecipients` changes from `emptyRecipients(event: String)` to
  `emptyRecipients(event: String, type: String)`.
- Consumes: nothing new — `IdentifierValidation.validate(_:kind:)` (existing, `.recipient` kind)
  unchanged.

- [ ] **Step 1: Write the failing tests**

Find the existing parser tests in `Tests/DomainEventGeneratorTests/NotificationGeneratorTests.swift`
(search for `NotificationDefinitionParser.parse` — they assert on `EventNotificationDefinition`
and `NotificationEntry` shapes). Add these new tests alongside them:

```swift
@Test("recipients live per notification-type entry, not per event")
func recipientsPerEntry() throws {
    let yaml = """
    AssignedMemberAdded:
      notifications:
        - type: mail
          recipients:
            - departmentLeadId
          subject: s
          content: c
        - type: inApp
          recipients:
            - memberIds
          title: t
          content: c
    """
    let definitions = try NotificationDefinitionParser.parse(yaml: yaml)
    let event = try #require(definitions.first)
    #expect(event.notifications[0].recipients == ["departmentLeadId"])
    #expect(event.notifications[1].recipients == ["memberIds"])
}

@Test("an entry with empty recipients throws, naming that entry's type")
func emptyRecipientsPerEntryThrows() throws {
    let yaml = """
    AssignedMemberAdded:
      notifications:
        - type: mail
          recipients: []
          subject: s
          content: c
    """
    #expect(throws: NotificationParseError.emptyRecipients(event: "AssignedMemberAdded", type: "mail")) {
        _ = try NotificationDefinitionParser.parse(yaml: yaml)
    }
}

@Test("a missing recipients key on an entry throws the same emptyRecipients error")
func missingRecipientsKeyThrows() throws {
    let yaml = """
    AssignedMemberAdded:
      notifications:
        - type: inApp
          title: t
          content: c
    """
    #expect(throws: NotificationParseError.emptyRecipients(event: "AssignedMemberAdded", type: "inApp")) {
        _ = try NotificationDefinitionParser.parse(yaml: yaml)
    }
}
```

Also **update** every existing test in this file that constructs YAML with a top-level
`recipients:` key under the event (not under a `notifications:` entry) — move that key down into
each `notifications:` entry it applies to. Update every existing assertion that reads
`event.recipients` (the old event-level field) to instead read `event.notifications[n].recipients`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter NotificationGeneratorTests 2>&1 | tail -60` (from the swift-ddd-kit repo
root). Expected: compile failure (`EventNotificationDefinition` has no member `recipients` once
you've updated the assertions — or the new tests fail to find `recipients` on `NotificationEntry`
if you haven't touched the source yet; either way, red before the source change).

- [ ] **Step 3: Update the source**

Replace `NotificationEntry`, `EventNotificationDefinition`, and `NotificationParseError` in
`NotificationDefinitionFile.swift`:

```swift
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

package struct EventNotificationDefinition: Equatable {
    package let eventName: String
    package let notifications: [NotificationEntry]

    package init(eventName: String, notifications: [NotificationEntry]) {
        self.eventName = eventName
        self.notifications = notifications
    }
}

package enum NotificationParseError: Error, Equatable, Sendable {
    case unknownType(event: String, type: String)
    case duplicateType(event: String, type: String)
    case missingField(event: String, type: String, field: String)
    case extraField(event: String, type: String, field: String)
    case invalidRenderFormat(event: String, type: String, value: String)
    case emptyRecipients(event: String, type: String)
    case emptyNotifications(event: String)
}
```

Update `NotificationParseError`'s `description`:

```swift
case .emptyRecipients(let event, let type):
    return "event '\(event)': notification type '\(type)' has empty `recipients`"
```

Replace the body of `NotificationDefinitionParser.parse(yaml:)` (the whole function — the
`recipients` extraction moves from before the `notifications` loop to inside it):

```swift
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
```

Note what moved: `recipients` extraction and its `emptyRecipients`/`IdentifierValidation` checks
are now INSIDE the `for entryNode in notificationsSequence` loop, using `entryMapping` (the
notification entry's own mapping) instead of `eventMapping` (the event's mapping). `allowedKeys`
gains `"recipients"` so it doesn't trip `extraField`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter NotificationGeneratorTests 2>&1 | tail -60`. Expected: all pass,
including the 3 new tests and every updated existing test.

- [ ] **Step 5: Commit**

```bash
git add Sources/DomainEventGenerator/Generator/Notification/NotificationDefinitionFile.swift Tests/DomainEventGeneratorTests/NotificationGeneratorTests.swift
git commit -m "feat: move notification.yaml recipients into per-type entries"
```

---

### Task 2: `RenderedNotification.recipients` + generator computes recipients per-entry

**Files:**
- Modify: `Sources/NotificationDefinition/NotificationDefinition.swift`
- Modify: `Sources/DomainEventGenerator/Generator/Notification/NotificationGenerator.swift`
- Test: `Tests/NotificationDefinitionTests/` (find `RenderedNotification`'s existing tests —
  search for `RenderedNotification(type:` if unsure of the exact file)
- Test: `Tests/DomainEventGeneratorTests/NotificationGeneratorTests.swift` (generator golden-output
  tests — search for `NotificationGenerator(protocolName:`)

**Interfaces:**
- Consumes: Task 1's `NotificationEntry.recipients: [String]`.
- Produces: `RenderedNotification.recipients: [String]`. The generated `<Event>Notification` enum
  no longer has a standalone `static func recipients(input:) -> [String]` — `render(input:
  variables:)` is the only generated function left, and each `RenderedNotification` it returns
  carries its own resolved recipients.

- [ ] **Step 1: Write the failing test for `RenderedNotification`**

Add to `Tests/NotificationDefinitionTests/` (in whichever existing test file covers
`RenderedNotification` — if none is dedicated, add to the file testing `payloadEntries`):

```swift
@Test("RenderedNotification carries its own recipients")
func renderedNotificationCarriesRecipients() {
    let notification = RenderedNotification(
        type: .mail, recipients: ["acct-1", "acct-2"], fields: ["subject": "s", "content": "c"])
    #expect(notification.recipients == ["acct-1", "acct-2"])
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter NotificationDefinitionTests 2>&1 | tail -30`. Expected: compile failure —
`RenderedNotification.init` has no `recipients` parameter yet.

- [ ] **Step 3: Update `RenderedNotification`**

In `Sources/NotificationDefinition/NotificationDefinition.swift`:

```swift
public struct RenderedNotification: Equatable, Sendable {
    public let type: NotificationType
    public let recipients: [String]
    public let fields: [String: String]

    public init(type: NotificationType, recipients: [String], fields: [String: String]) {
        self.type = type
        self.recipients = recipients
        self.fields = fields
    }
}
```

(`payloadEntries` and everything else in this file is unaffected — leave it as-is.)

- [ ] **Step 4: Run to verify Step 1's test passes**

Run: `swift test --filter NotificationDefinitionTests 2>&1 | tail -30`. Expected: pass. This will
also break every other call site constructing `RenderedNotification(type:fields:)` without
`recipients:` — that's expected and fixed in the remaining steps.

- [ ] **Step 5: Write the failing generator golden-output test**

In `Tests/DomainEventGeneratorTests/NotificationGeneratorTests.swift`, find the existing golden-
output test(s) that assert on the generated `render(input:variables:)` string output (search for
`"return \["` or `"RenderedNotification("` in the expected-output assertions). Add:

```swift
@Test("generated render() embeds each entry's own recipients, no standalone recipients(input:) function")
func generatedRenderEmbedsPerEntryRecipients() throws {
    let events = try NotificationDefinitionParser.parse(yaml: """
    AssignedMemberAdded:
      notifications:
        - type: mail
          recipients:
            - departmentLeadId
          subject: s
          content: c
        - type: inApp
          recipients:
            - memberIds
          title: t
          content: c
    """)
    let generator = NotificationGenerator(protocolName: "V", events: events, variables: [])
    let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

    #expect(output.contains(
        "RenderedNotification(type: NotificationType(rawValue: \"mail\")!, recipients: [input.departmentLeadId],"))
    #expect(output.contains(
        "RenderedNotification(type: NotificationType(rawValue: \"inApp\")!, recipients: [input.memberIds],"))
    #expect(!output.contains("static func recipients(input:"))
}
```

- [ ] **Step 6: Run to verify it fails**

Run: `swift test --filter NotificationGeneratorTests 2>&1 | tail -60`. Expected: fails — the
generator still emits the old `recipients(input:)` function and doesn't pass `recipients:` to
`RenderedNotification(...)`.

- [ ] **Step 7: Update `NotificationGenerator.swift`**

In `render(accessLevel:)`, the `propertyNames` computation currently seeds from `event.recipients`
(the now-removed event-level field). Change it to union every entry's recipients:

```swift
var propertyNames: Set<String> = []
for entry in event.notifications {
    propertyNames.formUnion(entry.recipients)
}
for variable in matchedVariables {
    for input in variable.inputs {
        propertyNames.insert(input.name)
    }
}
```

In `renderNotificationEnum(...)`, delete the entire `recipients(input:)` block (the 5 lines from
`// recipients(input:)` through the blank line after it). In the `for entry in event.notifications`
loop that builds the `return [ ... ]` array, change the `RenderedNotification(` line to include
`recipients:`, computed the same way the old standalone function did but scoped to this entry:

```swift
for entry in event.notifications {
    let recipientExpressions = entry.recipients.map { "input.\($0)" }.joined(separator: ", ")
    lines.append("            RenderedNotification(")
    lines.append("                type: NotificationType(rawValue: \"\(entry.type)\")!,")
    lines.append("                recipients: [\(recipientExpressions)],")
    lines.append("                fields: [")
    // ... existing field-building code unchanged ...
```

(Only the three new/changed lines are shown — the field-building code inside this loop, and
everything else in the file, is untouched.)

- [ ] **Step 8: Run to verify Steps 1 and 5's tests pass**

Run: `swift test --filter "NotificationDefinitionTests|NotificationGeneratorTests" 2>&1 | tail -80`.
Expected: all pass. Fix any other existing golden-output assertions in
`NotificationGeneratorTests.swift` that still expect the old `RenderedNotification(type:` (without
`recipients:`) or that assert `recipients(input:)` exists — update them to the new shape.

- [ ] **Step 9: Commit**

```bash
git add Sources/NotificationDefinition/NotificationDefinition.swift Sources/DomainEventGenerator/Generator/Notification/NotificationGenerator.swift Tests/NotificationDefinitionTests Tests/DomainEventGeneratorTests/NotificationGeneratorTests.swift
git commit -m "feat: RenderedNotification carries its own recipients, generator drops standalone recipients(input:)"
```

---

### Task 3: `ForwardingRule.translate` returns multiple published events

**Files:**
- Modify: `Sources/ContextForwarder/ForwardingRule.swift`
- Modify: `Sources/ContextForwarder/ContextForwarder.swift`
- Test: `Tests/ContextForwarderTests/ForwardingRuleTests.swift`

**Interfaces:**
- Produces: `ForwardingRule.translate: @Sendable (ForwardedRecord) async throws -> [PublishedLanguageEvent]`
  (was `-> PublishedLanguageEvent?`). An empty array means "not notification-worthy" (was `nil`).
- Consumes: nothing new from Tasks 1-2 — this task is independent of the schema/generator change
  at the type-checker level (OC's own glue code, not touched by this plan, is what will actually
  bridge `[RenderedNotification]` into this new array-returning shape — see the plan for OC's
  migration).

- [ ] **Step 1: Write the failing test**

In `Tests/ContextForwarderTests/ForwardingRuleTests.swift`, add:

```swift
@Test("a rule can translate one record into multiple published events")
func ruleTranslatesToMultipleEvents() async throws {
    let rule = ForwardingRule(eventTypes: ["CollaboratorAdded"]) { record in
        let body = try record.decodeBody(CollaboratorAddedBody.self)
        return [
            PublishedLanguageEvent(
                eventId: "\(record.eventId)#mail",
                eventType: "OpportunityCollaboratorAdded.v1",
                occurredAt: try record.decodeOccurred(),
                recipientIds: [body.collaboratorId],
                payload: ["mail.role": body.role]),
            PublishedLanguageEvent(
                eventId: "\(record.eventId)#inApp",
                eventType: "OpportunityCollaboratorAdded.v1",
                occurredAt: try record.decodeOccurred(),
                recipientIds: [body.collaboratorId],
                payload: ["inApp.role": body.role]),
        ]
    }
    let record = ForwardedRecord(
        eventType: "CollaboratorAdded", streamName: "s-1", eventId: "e-1",
        data: #"{"collaboratorId":"acc-1","role":"editor","occurred":1756252800}"#.data(using: .utf8)!)

    let events = try await rule.translate(record)

    #expect(events.count == 2)
    #expect(events[0].eventId == "e-1#mail")
    #expect(events[1].eventId == "e-1#inApp")
}

@Test("a rule can still skip a record by returning an empty array")
func ruleSkipsWithEmptyArray() async throws {
    let rule = ForwardingRule(eventTypes: ["CollaboratorAdded"]) { record in
        let body = try record.decodeBody(CollaboratorAddedBody.self)
        return body.role == "viewer" ? [] : [/* ... */]
    }
    let record = ForwardedRecord(
        eventType: "CollaboratorAdded", streamName: "s-1", eventId: "e-1",
        data: #"{"collaboratorId":"acc-1","role":"viewer"}"#.data(using: .utf8)!)

    let events = try await rule.translate(record)
    #expect(events.isEmpty)
}
```

Update the existing `"a rule translates matching records and can skip with nil"` test (from
Step 1's read of the current file) to the new array-returning shape: change its closure's
`return nil` to `return []` and its non-skip `return PublishedLanguageEvent(...)` to
`return [PublishedLanguageEvent(...)]`, and its assertions from optional-unwrapping
(`try #require(...)`) to indexing into the returned array (`events[0]`).

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ForwardingRuleTests 2>&1 | tail -60` (from swift-ddd-kit repo root).
Expected: compile failure — `ForwardingRule.init`'s `translate` closure type doesn't match an
array-returning closure yet.

- [ ] **Step 3: Update `ForwardingRule.swift`**

```swift
public struct ForwardingRule: Sendable {
    public let eventTypes: Set<String>
    public let translate: @Sendable (ForwardedRecord) async throws -> [PublishedLanguageEvent]

    public init(
        eventTypes: Set<String>,
        translate: @escaping @Sendable (ForwardedRecord) async throws -> [PublishedLanguageEvent]
    ) {
        self.eventTypes = eventTypes
        self.translate = translate
    }
}
```

Update the type's doc comment's "Returning nil skips the record" line to "Returning an empty array
skips the record".

- [ ] **Step 4: Update `ContextForwarder.swift`'s `consume()`**

Find the `for rule in rules where rule.eventTypes.contains(record.eventType)` loop inside
`consume()`. Change:

```swift
if let published = try await rule.translate(record) {
    try await publisher.publish(published)
    logger.info("\(stream)/\(groupName): forwarded \(record.eventType) -> \(published.eventType) (\(published.eventId))")
}
```

to:

```swift
for published in try await rule.translate(record) {
    try await publisher.publish(published)
    logger.info("\(stream)/\(groupName): forwarded \(record.eventType) -> \(published.eventType) (\(published.eventId))")
}
```

(The surrounding `do { ... } catch { failures.append(error) }` and everything after the loop —
the disposition switch — is unchanged. A `translate` call itself still throws exactly as before;
only its successful-return shape changed from optional to array, and a `for` loop over an empty
array is a correct, silent no-op, matching the old `if let` skipping on `nil`.)

- [ ] **Step 5: Run to verify Step 1's tests pass**

Run: `swift test --filter ForwardingRuleTests 2>&1 | tail -60`. Expected: all pass, including the 2
new tests and the updated existing one.

- [ ] **Step 6: Run the full ContextForwarder suite**

Run: `swift test --filter ContextForwarderTests 2>&1 | tail -80`. Expected: all pass, including
`MultiRuleDispositionTests` (untouched, per Global Constraints) and any other test file in this
target that constructs a `ForwardingRule` — fix any you find still using the old
optional-returning closure shape.

- [ ] **Step 7: Commit**

```bash
git add Sources/ContextForwarder/ForwardingRule.swift Sources/ContextForwarder/ContextForwarder.swift Tests/ContextForwarderTests/ForwardingRuleTests.swift
git commit -m "feat: ForwardingRule.translate returns multiple published events, not one optional"
```

---

## Final Verification

Run the full suite from the swift-ddd-kit repo root: `swift test 2>&1 | tail -100`. Expected: same
pass/fail baseline as before this plan started (the only pre-existing failures should be
infrastructure-dependent integration tests requiring a live KurrentDB/Postgres connection — nothing
in `DomainEventGeneratorTests`, `NotificationDefinitionTests`, or `ContextForwarderTests` should be
red).
