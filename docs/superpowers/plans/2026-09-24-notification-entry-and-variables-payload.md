# Notification Entry Id & Variables on the Wire — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every rendered notification carries the `notification.yaml` entry id and the resolved placeholder values, and flattens them onto the Published Language payload as `{type}.entry` and `{type}.var.{Placeholder}`.

**Architecture:** `RenderedNotification` (runtime, `NotificationDefinition` module) gains two stored properties with defaulted initializer parameters, so every existing hand-written `RenderedNotification(...)` call keeps compiling. `payloadEntries` emits the two new key families next to the existing `{type}.{field}` keys. The code generator's default `render()` passes the entry's `id` literal and its already-built `values` dictionary into the new parameters. No change to `PayloadKey`, `PublishedLanguageEvent`, or any consumer.

**Tech Stack:** Swift 6.0 tools (6.2 toolchain), Swift Testing (`import Testing`, `@Suite`/`@Test`/`#expect`), SwiftPM build-tool plugin `NotificationGeneratorPlugin`.

**Spec:** `/Volumes/Development/NotificationContext/.claude/worktrees/mail-cc-rules-design/docs/superpowers/specs/2026-09-23-mail-cc-rules-design.md` §3 (branch `docs/mail-cc-rules-design` of NotificationContext). This plan is sub-project 1 of 6 in that spec's §11.

**Working directory for every command:** `/Volumes/Development/swift-ddd-kit/.claude/worktrees/notification-entry-and-variables-payload` (branch `feat/notification-entry-and-variables-payload`, cut from `origin/main` at `36ba312e`). PR base is `main`.

## Global Constraints

- Additive only: `PublishedLanguageEvent` schema rule is "only ADD optional payload keys". No existing payload key may change name or value.
- Source compatibility: every existing call `RenderedNotification(type:recipients:fields:)` must compile unchanged (the demo's `CollaboratorAddedInAppNotification.render` and downstream OC code depend on it). New initializer parameters therefore have defaults.
- **Spec deviation (deliberate):** spec §3.1 shows `entryId: String` non-optional. This plan makes it `String?` defaulting to `nil`, because a non-optional parameter without a default breaks source compatibility for hand-written `render()` overrides, and a defaulted non-optional would need a fake sentinel id. `nil` means "this notification was not rendered by a generated default `render()`", and no `{type}.entry` key is emitted. Task 3 updates the spec text to match.
- Key names, verbatim: `{type}.entry` and `{type}.var.{Placeholder}`, where `{type}` is `NotificationType.rawValue` (`mail` / `inApp`) and `{Placeholder}` is the placeholder name exactly as written between `%…%` (e.g. `QuotingCaseGroupName`).
- Both channels carry the keys (spec §1 decision "mail 與 inApp 都帶").
- `variables` holds only the placeholders referenced by THIS entry (its fields plus its template slots) — the same set the generated `values` dictionary already contains. No other event data goes on the wire.
- Values are the raw resolved variable values, never Markdown-escaped or HTML-rendered (escaping happens only inside `PlaceholderSubstitution.substitute(..., escaping: .markdown)` for `content`, which does not mutate `values`).
- Collision rule: a key produced from `fields` always wins over a key produced from `entryId`/`variables`. `payloadEntries` must never trap on duplicate keys.
- Release: additive minor within 1.4.x (tagging is out of scope for this plan).

## Review Focus

1. **Hand-written `render()` overrides** (demo's `CollaboratorAddedInAppNotification`, any downstream conformer) build `RenderedNotification` without the new arguments — expected: compiles, `entryId == nil`, `variables == [:]`, payload has no `.entry` and no `.var.` keys, existing keys unchanged. Pinned in Task 1 (`defaultsKeepLegacyPayload`) and Task 3 (`overriddenRenderCarriesNoEntryOrVariables`).
2. **A variable resolving to an empty string** — expected: `{type}.var.X` is still emitted with value `""` (the receiver decides what empty means; dropping it would make "value is empty" indistinguishable from "no such variable"). Pinned in Task 1 (`emptyVariableValueIsEmitted`).
3. **A `fields` key that collides with a new key** (e.g. a hand-built `fields: ["entry": "x"]`) — expected: no crash, the `fields` value wins. Today's `Dictionary(uniqueKeysWithValues:)` would trap if the new keys were naively appended. Pinned in Task 1 (`fieldsWinOnKeyCollision`).
4. **A placeholder used only inside a mail `template:` slot** — expected: it is in `values`, so it appears as `mail.var.X`. Pinned in Task 2 (`slotOnlyPlaceholderIsPassedAsVariable`).
5. **An entry with no placeholders at all** — expected: generated code passes `variables: [:]` (there is no `values` local to reference), still passes `entryId`. Pinned in Task 2 (`entryWithoutPlaceholdersPassesEmptyVariables`).

Known downstream effect, not fixed here: `RenderedNotification` is `Equatable`; two renders that differ only in `variables` now compare unequal. OpportunityContext forwarder tests that compare whole `RenderedNotification` values may need updated expectations when OC bumps its pin (sub-project 2).

---

### Task 1: `RenderedNotification` carries `entryId` and `variables`, flattened by `payloadEntries`

**Files:**
- Modify: `Sources/NotificationDefinition/NotificationDefinition.swift:9-30` (the `RenderedNotification` struct and its `payloadEntries` extension)
- Test: `Tests/NotificationDefinitionTests/WireContractTests.swift` (add a new suite at the end of the file)

**Interfaces:**
- Consumes: nothing new.
- Produces (Task 2 and Task 3 rely on these exact names):
  ```swift
  public struct RenderedNotification: Equatable, Sendable {
      public let type: NotificationType
      public let entryId: String?
      public let recipients: [String]
      public let fields: [String: String]
      public let variables: [String: String]
      public init(type: NotificationType, entryId: String? = nil, recipients: [String],
                  fields: [String: String], variables: [String: String] = [:])
      public var payloadEntries: [String: String] { get }
  }
  ```
  Argument order in the initializer is `type, entryId, recipients, fields, variables`.

- [ ] **Step 1: Write the failing tests**

Append to the end of `Tests/NotificationDefinitionTests/WireContractTests.swift`:

```swift
@Suite("RenderedNotification entry id and variables")
struct RenderedNotificationEntryAndVariablesTests {

    @Test("entryId flattens to \"{type}.entry\" for mail and inApp")
    func entryIdFlattens() {
        let mail = RenderedNotification(
            type: .mail, entryId: "assigned-member-added-mail-for-members", recipients: [],
            fields: ["subject": "S", "content": "C"])
        let inApp = RenderedNotification(
            type: .inApp, entryId: "assigned-member-added-in-app-for-members", recipients: [],
            fields: ["title": "T", "content": "C"])
        #expect(mail.payloadEntries["mail.entry"] == "assigned-member-added-mail-for-members")
        #expect(inApp.payloadEntries["inApp.entry"] == "assigned-member-added-in-app-for-members")
    }

    @Test("each variable flattens to \"{type}.var.{Placeholder}\"")
    func variablesFlatten() {
        let notification = RenderedNotification(
            type: .mail, entryId: "e", recipients: [],
            fields: ["subject": "S", "content": "C"],
            variables: ["AssignedDepartment": "審計一組", "QuotingCaseGroupName": "6666"])
        #expect(notification.payloadEntries == [
            "mail.subject": "S",
            "mail.content": "C",
            "mail.entry": "e",
            "mail.var.AssignedDepartment": "審計一組",
            "mail.var.QuotingCaseGroupName": "6666",
        ])
    }

    @Test("defaults keep the legacy payload exactly: no entry key, no var keys")
    func defaultsKeepLegacyPayload() {
        let notification = RenderedNotification(
            type: .inApp, recipients: ["acct-1"], fields: ["title": "T", "content": "C", "render": "plaintext"])
        #expect(notification.entryId == nil)
        #expect(notification.variables == [:])
        #expect(notification.payloadEntries == [
            "inApp.title": "T", "inApp.content": "C", "inApp.render": "plaintext",
        ])
    }

    @Test("a variable resolving to an empty string is still emitted")
    func emptyVariableValueIsEmitted() {
        let notification = RenderedNotification(
            type: .mail, entryId: "e", recipients: [],
            fields: ["subject": "S", "content": "C"], variables: ["CollaboratorDescription": ""])
        #expect(notification.payloadEntries["mail.var.CollaboratorDescription"] == "")
    }

    @Test("a fields key colliding with a generated key wins, and nothing traps")
    func fieldsWinOnKeyCollision() {
        let notification = RenderedNotification(
            type: .mail, entryId: "from-entry-id", recipients: [],
            fields: ["subject": "S", "content": "C", "entry": "from-fields", "var.X": "from-fields"],
            variables: ["X": "from-variables"])
        #expect(notification.payloadEntries["mail.entry"] == "from-fields")
        #expect(notification.payloadEntries["mail.var.X"] == "from-fields")
    }

    @Test("PayloadKey.parse keeps the var. prefix on the field half")
    func parseKeepsVarPrefix() {
        let parsed = PayloadKey.parse("mail.var.AssignedDepartment")
        #expect(parsed?.type == .mail)
        #expect(parsed?.field == "var.AssignedDepartment")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter RenderedNotificationEntryAndVariablesTests 2>&1 | tail -20`
Expected: build FAILS with errors like `extra argument 'entryId' in call` and `value of type 'RenderedNotification' has no member 'entryId'`.

- [ ] **Step 3: Implement**

In `Sources/NotificationDefinition/NotificationDefinition.swift`, replace the whole `RenderedNotification` struct and its `payloadEntries` extension (currently lines 9–30) with:

```swift
/// One rendered notification for a single channel, ready to be flattened into
/// the Published Language event's `payload` (see spec §6).
///
/// `entryId` is the `notification.yaml` entry's `id`, and `variables` the placeholder values the
/// generated default `render()` resolved for that entry. Both exist so a receiving context can
/// match rules against "which notification" and "with which values" without querying back
/// upstream (NotificationContext mail Cc rules spec §3). A hand-written `render()` that omits
/// them gets `nil` / `[:]`, and the payload carries no `.entry` / `.var.` keys.
public struct RenderedNotification: Equatable, Sendable {
    public let type: NotificationType
    public let entryId: String?
    public let recipients: [String]
    public let fields: [String: String]
    public let variables: [String: String]

    public init(
        type: NotificationType,
        entryId: String? = nil,
        recipients: [String],
        fields: [String: String],
        variables: [String: String] = [:]
    ) {
        self.type = type
        self.entryId = entryId
        self.recipients = recipients
        self.fields = fields
        self.variables = variables
    }
}

extension RenderedNotification {
    /// Flattens this notification to the cross-context Published Language payload key convention:
    /// - every `fields` entry → `"{type}.{field}"` (e.g. `"mail.subject"`), see spec §6;
    /// - `entryId`, when non-nil → `"{type}.entry"`;
    /// - every `variables` entry → `"{type}.var.{Placeholder}"`.
    ///
    /// On a key collision the `fields`-derived value wins; this never traps.
    public var payloadEntries: [String: String] {
        let prefix = type.rawValue
        var entries: [String: String] = [:]
        for (name, value) in variables {
            entries["\(prefix).var.\(name)"] = value
        }
        if let entryId {
            entries["\(prefix).entry"] = entryId
        }
        for (field, value) in fields {
            entries["\(prefix).\(field)"] = value
        }
        return entries
    }
}
```

- [ ] **Step 4: Run the new tests and the whole module's tests**

Run: `swift test --filter NotificationDefinitionTests 2>&1 | tail -20`
Expected: all tests PASS, including the pre-existing `RenderedNotificationPayloadEntriesTests` and `PayloadKeyParseTests`.

- [ ] **Step 5: Commit**

```bash
git add Sources/NotificationDefinition/NotificationDefinition.swift Tests/NotificationDefinitionTests/WireContractTests.swift
git commit -m "feat(notification): RenderedNotification carries entryId and variables onto the payload

Flattens to {type}.entry and {type}.var.{Placeholder}; both initializer
parameters default so hand-written render() overrides keep compiling.
fields-derived keys win on collision instead of trapping.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Generated default `render()` passes `entryId` and `variables`

**Files:**
- Modify: `Sources/DomainEventGenerator/Generator/Notification/NotificationGenerator.swift` inside `renderProtocolAndExtension` — the block that emits `return RenderedNotification(` … `])` (currently lines ~246–292)
- Test: `Tests/DomainEventGeneratorTests/NotificationGeneratorTests.swift` (add tests at the end of the `NotificationGeneratorTests` suite, before its closing `}`)

**Interfaces:**
- Consumes (from Task 1): `RenderedNotification.init(type:entryId:recipients:fields:variables:)` with that exact argument order.
- Produces: generated code of this exact shape (Task 3's demo compiles against it):
  ```swift
          return RenderedNotification(
              type: NotificationType(rawValue: "mail")!,
              entryId: "collaborator-added-mail",
              recipients: try await self.recipients(),
              fields: [
                  ...
              ],
              variables: values)
  ```
  where `variables:` is `values` when the entry references at least one placeholder and `[:]` otherwise.

- [ ] **Step 1: Write the failing tests**

Insert before the final closing `}` of `struct NotificationGeneratorTests` in `Tests/DomainEventGeneratorTests/NotificationGeneratorTests.swift`:

```swift
    @Test("default render() passes the entry id literal as entryId")
    func defaultRenderPassesEntryId() throws {
        let generator = NotificationGenerator(
            protocolName: "OpportunityNotificationVariables",
            events: [Self.collaboratorAddedEvent],
            variables: Self.variables)
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(output.contains(
            "            type: NotificationType(rawValue: \"mail\")!,\n            entryId: \"collaborator-added-mail\",\n            recipients: try await self.recipients(),"))
        #expect(output.contains(
            "            type: NotificationType(rawValue: \"inApp\")!,\n            entryId: \"collaborator-added-in-app\",\n            recipients: try await self.recipients(),"))
    }

    @Test("default render() passes the resolved values dictionary as variables")
    func defaultRenderPassesValuesAsVariables() throws {
        let generator = NotificationGenerator(
            protocolName: "OpportunityNotificationVariables",
            events: [Self.collaboratorAddedEvent],
            variables: Self.variables)
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(output.contains("            ],\n            variables: values)"))
        #expect(!output.contains("            ])\n    }"))
    }

    @Test("an entry without placeholders passes variables: [:] and still passes entryId")
    func entryWithoutPlaceholdersPassesEmptyVariables() throws {
        let event = EventNotificationDefinition(
            eventName: "Foo",
            notifications: [
                NotificationEntry(id: "static-mail", type: "mail", render: .plaintext, fields: [(name: "subject", template: "hi"), (name: "content", template: "static text")]),
            ])
        let generator = NotificationGenerator(protocolName: "P", events: [event], variables: [])
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(output.contains("            entryId: \"static-mail\","))
        #expect(output.contains("            ],\n            variables: [:])"))
    }

    @Test("a placeholder used only in a template slot is part of the values passed as variables")
    func slotOnlyPlaceholderIsPassedAsVariable() throws {
        let generator = NotificationGenerator(
            protocolName: "P", events: [Self.templatedMailEvent], variables: [Self.caseIdVariable])
        let output = try generator.render(accessLevel: .internal).joined(separator: "\n")

        #expect(output.contains("        let values: [String: String] = [\n            \"CaseId\": caseId,\n        ]"))
        #expect(output.contains("            entryId: \"templated-mail\","))
        #expect(output.contains("            ],\n            variables: values)"))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter NotificationGeneratorTests 2>&1 | tail -20`
Expected: the four new tests FAIL (`output.contains(...)` is false); all pre-existing tests still PASS.

- [ ] **Step 3: Implement**

In `renderProtocolAndExtension` of `NotificationGenerator.swift`:

(a) Replace

```swift
        lines.append("        return RenderedNotification(")
        lines.append("            type: NotificationType(rawValue: \"\(entry.type)\")!,")
        lines.append("            recipients: try await self.recipients(),")
```

with

```swift
        lines.append("        return RenderedNotification(")
        lines.append("            type: NotificationType(rawValue: \"\(entry.type)\")!,")
        // Wire model: the entry id and this entry's resolved placeholder values ride the payload
        // as `{type}.entry` / `{type}.var.<Placeholder>` so a receiver can match rules against
        // them (NotificationContext mail Cc rules spec §3). `entry.id` already passed the
        // `^[a-z][a-z0-9_-]*$` grammar at parse time, so it is safe inside a string literal.
        lines.append("            entryId: \"\(entry.id)\",")
        lines.append("            recipients: try await self.recipients(),")
```

(b) Replace the closing line of the fields literal

```swift
        lines.append("            ])")
        lines.append("    }")
```

with

```swift
        lines.append("            ],")
        lines.append("            variables: \(valuesArgument))")
        lines.append("    }")
```

`valuesArgument` is the existing local (`placeholders.isEmpty ? "[:]" : "values"`) declared just above the `for field in entry.fields` loop; it is in scope here. Do not introduce a second variable for it.

- [ ] **Step 4: Run the generator tests**

Run: `swift test --filter DomainEventGeneratorTests 2>&1 | tail -20`
Expected: all PASS, old and new.

- [ ] **Step 5: Commit**

```bash
git add Sources/DomainEventGenerator/Generator/Notification/NotificationGenerator.swift Tests/DomainEventGeneratorTests/NotificationGeneratorTests.swift
git commit -m "feat(notification-generator): default render() passes entryId and resolved variables

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: End-to-end demo proof, README, and spec alignment

**Files:**
- Test: `Tests/NotificationDefinitionDemoTests/DemoRenderTests.swift` (add two tests inside `struct DemoRenderTests`)
- Modify: `README.md` — insert a new paragraph block immediately after the paragraph that ends with the link to `2026-09-23-mail-template-field-design.md` (currently line 812), before the paragraph starting "`NotificationGeneratorPlugin` cross-validates"
- Modify (other repo): `/Volumes/Development/NotificationContext/.claude/worktrees/mail-cc-rules-design/docs/superpowers/specs/2026-09-23-mail-cc-rules-design.md` §3.1

**Interfaces:**
- Consumes: Task 1's `entryId` / `variables` / `payloadEntries`; Task 2's generated `render()` (built by `NotificationGeneratorPlugin` from `Sources/NotificationDefinitionDemo/notification.yaml`).
- Produces: nothing new for code.

The demo's mail entry is `collaborator-added-mail`. Its placeholders across fields and slots are `QuotingCaseGroupName`, `QuotingCaseGroupCollaboratorRole`, `CollaboratorDescription`; `DemoVariables` resolves them to `6666`, `編輯者`, `歡迎加入團隊` (confirmed by the existing `mailUsesDefaultRenderAndSubstitutesFieldsExactly` expectations). The demo's inApp conformer overrides `render()` without the new arguments.

- [ ] **Step 1: Write the tests**

Insert inside `struct DemoRenderTests`, after `mailTemplateFieldsAreRenderedAndExposedUnderTheirWireKeys`:

```swift
    @Test func generatedRenderCarriesEntryIdAndResolvedVariablesOntoThePayload() async throws {
        let notification = CollaboratorAddedMailNotification(event: makeEvent())
        let rendered = try await notification.render(variables: DemoVariables())

        #expect(rendered.entryId == "collaborator-added-mail")
        #expect(rendered.variables == [
            "QuotingCaseGroupName": "6666",
            "QuotingCaseGroupCollaboratorRole": "編輯者",
            "CollaboratorDescription": "歡迎加入團隊",
        ])
        let payload = rendered.payloadEntries
        #expect(payload["mail.entry"] == "collaborator-added-mail")
        #expect(payload["mail.var.QuotingCaseGroupName"] == "6666")
        #expect(payload["mail.var.QuotingCaseGroupCollaboratorRole"] == "編輯者")
        #expect(payload["mail.var.CollaboratorDescription"] == "歡迎加入團隊")
        // Pre-existing keys are untouched.
        #expect(payload["mail.subject"] == "你已被加入案件「6666」")
        #expect(payload["mail.template"] == "one-button")
    }

    @Test func overriddenRenderCarriesNoEntryOrVariables() async throws {
        let notification = CollaboratorAddedInAppNotification(event: makeEvent())
        let rendered = try await renderThroughProtocol(notification, variables: DemoVariables())

        #expect(rendered.entryId == nil)
        #expect(rendered.variables == [:])
        #expect(rendered.payloadEntries.keys.sorted() == ["inApp.content", "inApp.render", "inApp.title"])
    }
```

- [ ] **Step 2: Run the demo tests**

Run: `swift test --filter NotificationDefinitionDemoTests 2>&1 | tail -20`
Expected: all PASS (Tasks 1–2 already implement the behavior; this task proves the plugin-generated code compiles and behaves end to end). If `generatedRenderCarriesEntryIdAndResolvedVariablesOntoThePayload` fails on a value, re-read `Sources/NotificationDefinitionDemo/DemoVariables.swift` and correct the expected values to what `DemoVariables` actually returns — do not change `DemoVariables`.

- [ ] **Step 3: Document the wire keys in README**

Insert this block in `README.md` right after the paragraph ending with the `2026-09-23-mail-template-field-design.md` link:

```markdown
Every notification rendered by a generated default `render()` also carries two things a receiver
can match rules against without querying back upstream: the entry's `id` and the placeholder
values resolved for that entry. They ride `RenderedNotification.entryId` / `.variables` and flatten
to `{type}.entry` and `{type}.var.<Placeholder>`:

```text
mail.entry                         = collaborator-added-mail
mail.var.QuotingCaseGroupName      = 6666
mail.var.CollaboratorDescription   = 歡迎加入團隊
```

Values are the raw resolved values (never Markdown-escaped or HTML-rendered), and only this
entry's own placeholders (fields plus template slots) are included. A hand-written `render()` that
builds `RenderedNotification(type:recipients:fields:)` without them emits neither key family — both
initializer parameters default. If a `fields` key ever collides with one of these keys, the
`fields` value wins. Full design:
[`NotificationContext/docs/superpowers/specs/2026-09-23-mail-cc-rules-design.md`](https://github.com/Mendesky/NotificationContext/blob/main/docs/superpowers/specs/2026-09-23-mail-cc-rules-design.md) §3.
```

(The inner ```` ```text ```` fence is part of the inserted README content.)

- [ ] **Step 4: Run the full test suite**

Run: `swift test 2>&1 | tail -30`
Expected: every test PASSES. On macOS, `ContextReceiverWebSocket` tests are compiled out by design (README "macOS limitation"); that is not a failure. Record the final summary line (number of tests passed) for the PR description.

- [ ] **Step 5: Commit in swift-ddd-kit**

```bash
git add Tests/NotificationDefinitionDemoTests/DemoRenderTests.swift README.md
git commit -m "test(notification-demo): prove entry id and variables reach the payload end to end; document wire keys

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 6: Align the spec with the optional `entryId`**

In `/Volumes/Development/NotificationContext/.claude/worktrees/mail-cc-rules-design/docs/superpowers/specs/2026-09-23-mail-cc-rules-design.md` §3.1, replace

```swift
    public let entryId: String            // new：notification.yaml 該 entry 的 id
```

with

```swift
    public let entryId: String?           // new：notification.yaml 該 entry 的 id；手寫 render() 未提供 → nil，不輸出 {type}.entry
```

and replace the line `    public let variables: [String: String] // new：渲染該 entry 時解析到的 placeholder → 值` with

```swift
    public let variables: [String: String] // new：渲染該 entry 時解析到的 placeholder → 值；預設 [:]
```

Then append this sentence to the end of §3.2's bullet list:

```markdown
- 兩個新 init 參數都有預設值（`entryId: nil`、`variables: [:]`），既有手寫 `RenderedNotification(type:recipients:fields:)` 呼叫照舊編譯；`fields` 產生的 key 與新 key 撞名時 `fields` 優先。
```

Commit there:

```bash
git -C /Volumes/Development/NotificationContext/.claude/worktrees/mail-cc-rules-design add docs/superpowers/specs/2026-09-23-mail-cc-rules-design.md
git -C /Volumes/Development/NotificationContext/.claude/worktrees/mail-cc-rules-design commit -m "docs: entryId is optional with defaulted init params (ddd-kit plan)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

## After all tasks

Push `feat/notification-entry-and-variables-payload` and open a PR against `main` of `gradyzhuo/swift-ddd-kit`. The PR description names the spec, lists the two new key families, states the source-compatibility guarantee, and notes the downstream `Equatable` effect for the OC pin bump. End the description with:

🤖 Generated with [Claude Code](https://claude.com/claude-code)
