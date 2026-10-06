# ForwardedRecord Custom Metadata Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ForwardedRecord` carries the KurrentDB `customMetadata` bytes and lets a forwarding rule decode them with a schema the rule chooses.

**Architecture:** Add an optional `metadata: Data?` to the kit-agnostic `ForwardedRecord`, populated by `init(from: ReadEvent)` with empty bytes normalised to `nil`. Add `decodeMetadata<M: Decodable>(_:)` shaped like the existing `decodeBody(_:)`: `nil` metadata → `nil`, undecodable bytes → `ForwardingError.permanent`. No other ContextForwarder type changes; the new init parameter has a default so every existing caller compiles unchanged.

**Tech Stack:** Swift 6 package, swift-testing (`import Testing`, `@Suite`/`@Test`/`#expect`), swift-kurrentdb `ReadEvent`/`RecordedEvent`.

**Spec:** `docs/superpowers/specs/2026-10-06-forwarded-record-metadata-design.md`

## Global Constraints

- `ContextForwarder` target gains no new dependency; the generic constraint is `Decodable`, not `EventMetadata`.
- No concrete metadata schema is defined inside `ContextForwarder`; `CustomMetadata` stays in `KurrentSupport`.
- `ForwardingRule`, `ContextForwarder`, `ForwarderGroup` signatures do not change.
- Source-compatible: the existing 4-argument `ForwardedRecord.init(eventType:streamName:eventId:data:)` call sites (8 in `Tests/ContextForwarderTests`, plus the OC forwarder's tests) must compile and pass without edits.
- `permanent` reason format: `"decoding metadata as \(M.self) from \(eventType) (\(eventId)) failed: \(error)"`.
- Work happens in worktree `/Volumes/Development/swift-ddd-kit/.claude/worktrees/forwarded-record-metadata`, branch `feat/forwarded-record-metadata`. PR targets `main`. Release tag `1.4.0-beta.10` is cut by the user after merge.

## Review Focus

Inputs the spec implies but a careless implementation would get wrong, each pinned by a test in the owning task:

1. A writer that attached an **empty JSON object** `{}` — a rule whose type has a required field must get `permanent`, a rule whose type is all-optional must get a value with `nil` fields, never a silent `nil` record. (Task 2)
2. **Whitespace-only or non-UTF-8 bytes** — non-empty, so not "absent"; must be `permanent`, not `nil`. (Task 2)
3. **Extra unknown keys** in the metadata (another context's richer schema) — must still decode; `Decodable` ignores unknown keys, the test guards against anyone adding a strict decoder later. (Task 2)
4. **Existing callers** that never pass `metadata` — `record.metadata` must be `nil` and `decodeMetadata` must return `nil`, so a forwarder upgraded to beta.10 behaves exactly as before until a rule opts in. (Task 1)
5. **`permanent` reason must identify the record** — eventType and eventId both present, otherwise a parked message cannot be traced back. (Task 2)

---

### Task 1: `metadata` field, normalisation helper, source-compatible init

**Files:**
- Modify: `Sources/ContextForwarder/ForwardedRecord.swift`
- Test: `Tests/ContextForwarderTests/ForwardedRecordTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `ForwardedRecord.metadata: Data?`; `ForwardedRecord.init(eventType:streamName:eventId:data:metadata:)` with `metadata: Data? = nil`; `static func ForwardedRecord.normalizedMetadata(_ bytes: Data) -> Data?`. Task 3 calls `normalizedMetadata`; Task 2 reads `metadata`.

- [ ] **Step 1: Write the failing tests**

Append inside `struct ForwardedRecordTests` in `Tests/ContextForwarderTests/ForwardedRecordTests.swift` (before the closing `}` of the struct):

```swift
    // MARK: - metadata field

    @Test("existing 4-argument init leaves metadata nil")
    func legacyInitHasNilMetadata() {
        let record = ForwardedRecord(
            eventType: "X", streamName: "s", eventId: "e", data: Data())
        #expect(record.metadata == nil)
    }

    @Test("init stores the metadata bytes it is given")
    func initStoresMetadata() {
        let bytes = #"{"operatorId":"u-1"}"#.data(using: .utf8)!
        let record = ForwardedRecord(
            eventType: "X", streamName: "s", eventId: "e", data: Data(), metadata: bytes)
        #expect(record.metadata == bytes)
    }

    @Test("normalizedMetadata turns KurrentDB's empty Data into nil")
    func emptyBytesNormaliseToNil() {
        #expect(ForwardedRecord.normalizedMetadata(Data()) == nil)
    }

    @Test("normalizedMetadata passes non-empty bytes through untouched")
    func nonEmptyBytesPassThrough() {
        let bytes = #"{"operatorId":"u-1"}"#.data(using: .utf8)!
        #expect(ForwardedRecord.normalizedMetadata(bytes) == bytes)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run (from the worktree root):
```bash
swift test --filter ForwardedRecordTests 2>&1 | tail -20
```
Expected: compile error — `extra argument 'metadata' in call` and `type 'ForwardedRecord' has no member 'normalizedMetadata'`.

- [ ] **Step 3: Implement the field, init default, and helper**

In `Sources/ContextForwarder/ForwardedRecord.swift`, replace the stored properties and init:

```swift
public struct ForwardedRecord: Sendable {
    public let eventType: String
    public let streamName: String
    public let eventId: String
    public let data: Data
    /// KurrentDB `customMetadata` as raw bytes — whatever the writing context's
    /// `EventMetadata` struct JSON-encoded to (see
    /// `docs/superpowers/specs/2026-05-15-ambient-context-and-pluggable-metadata-design.md`).
    /// `nil` when the write carried no metadata; swift-kurrentdb hands that back
    /// as an empty `Data`, which `init(from:)` normalises so "absent" has exactly
    /// one spelling. Raw rather than typed on purpose: this record is
    /// kit-agnostic and each rule picks its own schema via `decodeMetadata(_:)`.
    public let metadata: Data?

    public init(
        eventType: String,
        streamName: String,
        eventId: String,
        data: Data,
        metadata: Data? = nil
    ) {
        self.eventType = eventType
        self.streamName = streamName
        self.eventId = eventId
        self.data = data
        self.metadata = metadata
    }

    /// `RecordedEvent.customMetadata` is a non-optional `Data` that is empty
    /// when nothing was written. Collapse that to `nil` so callers never have
    /// to ask "nil or empty?". Kept `static` and side-effect free so it is
    /// testable without constructing a `ReadEvent`.
    static func normalizedMetadata(_ bytes: Data) -> Data? {
        bytes.isEmpty ? nil : bytes
    }
```

Leave `decodeBody` and `decodeOccurred` exactly as they are.

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
swift test --filter ForwardedRecordTests 2>&1 | tail -20
```
Expected: all `ForwardedRecordTests` pass (the 2 pre-existing + 4 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/ContextForwarder/ForwardedRecord.swift Tests/ContextForwarderTests/ForwardedRecordTests.swift
git commit -m "feat(forwarder): ForwardedRecord carries raw customMetadata bytes

Optional, defaulted to nil so every existing caller compiles unchanged.
normalizedMetadata collapses KurrentDB's empty Data to nil.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: `decodeMetadata<M: Decodable>(_:)`

**Files:**
- Modify: `Sources/ContextForwarder/ForwardedRecord.swift`
- Test: `Tests/ContextForwarderTests/ForwardedRecordTests.swift`

**Interfaces:**
- Consumes: `ForwardedRecord.metadata: Data?` (Task 1); `ForwardingError.permanent(reason:)` (existing, `Sources/ContextForwarder/ForwardingError.swift`).
- Produces: `public func decodeMetadata<M: Decodable>(_ type: M.Type) throws -> M?`.

- [ ] **Step 1: Write the failing tests**

Append inside `struct ForwardedRecordTests`:

```swift
    // MARK: - decodeMetadata

    /// What a consuming context would declare: its own schema, nothing from the kit.
    private struct Operator: Decodable, Equatable {
        let operatorId: String
    }

    private struct LenientOperator: Decodable, Equatable {
        let operatorId: String?
    }

    private func record(metadata: Data?) -> ForwardedRecord {
        ForwardedRecord(
            eventType: "CollaboratorAdded", streamName: "s", eventId: "evt-42",
            data: Data(), metadata: metadata)
    }

    @Test("decodeMetadata decodes the bytes with the caller's type")
    func decodesMetadata() throws {
        let bytes = #"{"operatorId":"u-1"}"#.data(using: .utf8)!
        let decoded = try record(metadata: bytes).decodeMetadata(Operator.self)
        #expect(decoded == Operator(operatorId: "u-1"))
    }

    @Test("decodeMetadata returns nil when the record has no metadata")
    func absentMetadataIsNil() throws {
        let decoded = try record(metadata: nil).decodeMetadata(Operator.self)
        #expect(decoded == nil)
    }

    @Test("decodeMetadata ignores keys the caller's type does not declare")
    func unknownKeysAreIgnored() throws {
        let bytes = #"{"operatorId":"u-1","requestId":"r-9","tenant":"t"}"#.data(using: .utf8)!
        let decoded = try record(metadata: bytes).decodeMetadata(Operator.self)
        #expect(decoded == Operator(operatorId: "u-1"))
    }

    @Test("undecodable bytes are permanent and the reason names the record")
    func malformedBytesArePermanent() {
        let bytes = "not json".data(using: .utf8)!
        #expect {
            _ = try record(metadata: bytes).decodeMetadata(Operator.self)
        } throws: { error in
            guard case .permanent(let reason) = error as? ForwardingError else { return false }
            return reason.contains("CollaboratorAdded") && reason.contains("evt-42")
                && reason.contains("Operator")
        }
    }

    @Test("whitespace-only bytes are present-but-broken, so permanent, not nil")
    func whitespaceBytesArePermanent() {
        let bytes = "   \n".data(using: .utf8)!
        #expect(throws: ForwardingError.self) {
            _ = try record(metadata: bytes).decodeMetadata(Operator.self)
        }
    }

    @Test("non-UTF-8 bytes are permanent")
    func nonUTF8BytesArePermanent() {
        let bytes = Data([0xFF, 0xFE, 0x00])
        #expect(throws: ForwardingError.self) {
            _ = try record(metadata: bytes).decodeMetadata(Operator.self)
        }
    }

    @Test("a missing required field is permanent for a strict type")
    func missingRequiredFieldIsPermanent() {
        let bytes = #"{}"#.data(using: .utf8)!
        #expect(throws: ForwardingError.self) {
            _ = try record(metadata: bytes).decodeMetadata(Operator.self)
        }
    }

    @Test("the same bytes decode for a type that declares the field optional")
    func lenientTypeDecodesMissingField() throws {
        let bytes = #"{}"#.data(using: .utf8)!
        let decoded = try record(metadata: bytes).decodeMetadata(LenientOperator.self)
        #expect(decoded == LenientOperator(operatorId: nil))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
swift test --filter ForwardedRecordTests 2>&1 | tail -20
```
Expected: compile error `value of type 'ForwardedRecord' has no member 'decodeMetadata'`.

- [ ] **Step 3: Implement `decodeMetadata`**

In `Sources/ContextForwarder/ForwardedRecord.swift`, add after `decodeBody`:

```swift
    /// Decodes `metadata` with a schema the rule chooses — the read-side twin of
    /// the writing context's `EventMetadata` struct. The kit never names that
    /// schema; the constraint is plain `Decodable` so this target stays free of
    /// an `EventSourcing` dependency.
    ///
    /// - `metadata == nil` → `nil`. Absent metadata is a normal state (events
    ///   written before a context started attaching it), never an error.
    /// - Bytes present but not decodable as `M` (not JSON, or a field `M`
    ///   requires is missing) → `ForwardingError.permanent`, same reasoning as
    ///   `decodeBody`: redelivery will not change the bytes, so retrying only
    ///   burns budget while parking makes the record visible. A rule that wants
    ///   leniency declares optional fields on its own `M`; the kit does not guess.
    public func decodeMetadata<M: Decodable>(_ type: M.Type) throws -> M? {
        guard let metadata else { return nil }
        do {
            return try JSONDecoder().decode(type, from: metadata)
        } catch {
            throw ForwardingError.permanent(
                reason: "decoding metadata as \(M.self) from \(eventType) (\(eventId)) failed: \(error)")
        }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
swift test --filter ForwardedRecordTests 2>&1 | tail -20
```
Expected: all `ForwardedRecordTests` pass (14 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ContextForwarder/ForwardedRecord.swift Tests/ContextForwarderTests/ForwardedRecordTests.swift
git commit -m "feat(forwarder): decodeMetadata(_:) — rule-chosen schema, nil when absent, permanent when broken

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Populate `metadata` from the live `ReadEvent`

**Files:**
- Modify: `Sources/ContextForwarder/ContextForwarder.swift:245-264` (the `extension ForwardedRecord { init(from event: ReadEvent) }`)

**Interfaces:**
- Consumes: `ForwardedRecord.init(...metadata:)` and `ForwardedRecord.normalizedMetadata(_:)` (Task 1); swift-kurrentdb `RecordedEvent.customMetadata: Data`.
- Produces: nothing new; this is the wiring that makes Task 1/2 observable in production.

No offline unit test can construct a `ReadEvent` (its initialisers are `package`-scoped in swift-kurrentdb), and `Tests/ContextForwarderIntegrationTests` needs a live KurrentDB. The normalisation logic is already covered in Task 1; this task is verified by compile plus the full suite.

- [ ] **Step 1: Wire `customMetadata` through**

Replace the body of `init(from event: ReadEvent)` in `Sources/ContextForwarder/ContextForwarder.swift`:

```swift
    init(from event: ReadEvent) {
        let record = event.record
        self.init(
            eventType: record.eventType,
            streamName: record.streamIdentifier.name,
            eventId: record.id.uuidString,
            data: record.data,
            // `customMetadata` is a non-optional Data that is empty when the
            // writer attached nothing; normalise so rules see nil, not Data().
            metadata: Self.normalizedMetadata(record.customMetadata))
    }
```

Keep the existing doc comment above the init.

- [ ] **Step 2: Build and run the whole ContextForwarder suite**

Run:
```bash
swift build 2>&1 | tail -5 && swift test --filter ContextForwarderTests 2>&1 | tail -15
```
Expected: `Build complete!`; every `ContextForwarderTests` suite passes; `git diff --stat main -- Tests/` lists only `ForwardedRecordTests.swift` (no other test file needed editing — that is the source-compatibility proof).

- [ ] **Step 3: Commit**

```bash
git add Sources/ContextForwarder/ContextForwarder.swift
git commit -m "feat(forwarder): ForwardedRecord(from:) carries RecordedEvent.customMetadata

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Docs — file header and README

**Files:**
- Modify: `Sources/ContextForwarder/ForwardedRecord.swift:1-9` (type-level doc comment)
- Modify: `README.md` — the "Cross-Context Events (Pulsar)" section, after the "At-least-once delivery, host-side dedup" subsection (around line 800)

**Interfaces:** none.

- [ ] **Step 1: Update the type-level doc comment**

Replace the comment block directly above `public struct ForwardedRecord` with:

```swift
/// Kit-agnostic view of one recorded domain event — what a translate closure
/// sees. `data` is the raw JSON payload as stored in KurrentDB; `metadata` is
/// the raw `customMetadata` the writing context attached (nil when none).
///
/// Both are bytes, not types, on purpose: this module never learns a context's
/// event or metadata schema. A rule decodes with `decodeBody(_:)` /
/// `decodeMetadata(_:)` using its own types, so two rules on one forwarder may
/// read the same metadata with different shapes.
///
/// Deliberately carries NO timestamp: swift-kurrentdb's `RecordedEvent` has no
/// server-side created-date, so any time this type could offer would be
/// capture time masquerading as event time. Event time must come from the
/// event's own payload — see `decodeOccurred()`.
```

- [ ] **Step 2: Add the README subsection**

In `README.md`, insert after the paragraph that ends `rather than tracking a separate dedup table.` (end of the "At-least-once delivery, host-side dedup" subsection):

```markdown
### Reading custom metadata in a rule

`ForwardedRecord.metadata` carries the KurrentDB `customMetadata` bytes the writing context attached (the JSON encoding of its `EventMetadata` struct — see the pluggable-metadata design). The kit does not know that schema; a rule decodes it with its own type:

```swift
struct Operator: Decodable { let operatorId: String }

ForwardingRule(eventTypes: ["CollaboratorAdded"]) { record in
    let body = try record.decodeBody(CollaboratorAdded.self)
    let actor = try record.decodeMetadata(Operator.self)   // nil when the write carried no metadata
    …
}
```

Semantics mirror `decodeBody`: absent metadata is `nil`, never an error (events written before a context started attaching metadata stay forwardable); bytes that are present but do not decode as the requested type are `ForwardingError.permanent` and park the record, because redelivery cannot repair them. A rule that wants leniency declares optional fields on its own type.
```

- [ ] **Step 3: Build to make sure the doc comment compiles and nothing else moved**

Run:
```bash
swift build 2>&1 | tail -3 && git diff --stat
```
Expected: `Build complete!`; diff touches only `ForwardedRecord.swift` and `README.md`.

- [ ] **Step 4: Commit**

```bash
git add Sources/ContextForwarder/ForwardedRecord.swift README.md
git commit -m "docs(forwarder): document ForwardedRecord.metadata and decodeMetadata

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Full verification and PR

**Files:** none modified.

- [ ] **Step 1: Run the complete package test suite**

Run:
```bash
swift test 2>&1 | grep -E 'Test run|✘|error:' | tail -10
```
Expected: a single `Test run with N tests … passed` line; no `✘`, no `error:`. (On macOS the Linux-only `ContextReceiverWebSocket` tests are compiled out by `#if os(Linux)`; that is pre-existing and expected.)

- [ ] **Step 2: Confirm source compatibility against the OC forwarder's call sites**

Run:
```bash
grep -rn 'ForwardedRecord(' Tests/ContextForwarderTests | wc -l
git diff --stat main -- Tests/
```
Expected: the count is unchanged from before this branch (8 pre-existing call sites, plus the new helper in `ForwardedRecordTests`), and the diff lists only `Tests/ContextForwarderTests/ForwardedRecordTests.swift`.

- [ ] **Step 3: Push and open the PR against `main`**

```bash
git push -u origin feat/forwarded-record-metadata
gh pr create --base main \
  --title "feat(forwarder): ForwardedRecord carries custom metadata, rule-chosen decode" \
  --body "$(cat <<'EOF'
## Summary
- `ForwardedRecord` gains `metadata: Data?` — the KurrentDB `customMetadata` bytes, `nil` when the write attached none (empty `Data` normalised).
- `decodeMetadata<M: Decodable>(_:)` mirrors `decodeBody`: `nil` when absent, `ForwardingError.permanent` when present but undecodable. The kit names no schema; each rule brings its own type.
- Source-compatible: the new init parameter defaults to `nil`; no existing test changed.

Spec: `docs/superpowers/specs/2026-10-06-forwarded-record-metadata-design.md`
Plan: `docs/superpowers/plans/2026-10-06-forwarded-record-metadata.md`

## Why
OC's `CollaboratorAdded` / `DesignatedUserAdded` carry the operator only in metadata; the PL forwarder needs it for recipients and copy. First consumer lands in OpportunityPLForwarder after `1.4.0-beta.10`.

## Test plan
- [x] `swift test` green
- [x] `git diff --stat main -- Tests/` touches only `ForwardedRecordTests.swift`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4: Report**

Tell the user the PR link, the test count, and that `1.4.0-beta.10` should be tagged on the merge commit; the OC forwarder follow-up (wire `operatorId` from `record.decodeMetadata`, conformers for `DesignatedUserAdded`) is a separate bounded change in the forwarder repo.
