# ContextForwarder Hardening Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the five design gaps the module's owner ruled on (2026-08-13), so `ContextForwarder` arrives in its decided shape: honest event time (enforced by type), permanent-vs-transient error classification (park instead of retry-then-park), built-in parked-message monitoring, Pulsar auth support, and a multi-forwarder group with self-healing.

**Architecture:** Kept minimal and testable. Error classification is a pure `ForwardingDisposition` mapping (unit-testable without KurrentDB types) that `run()` translates into a nack action. Parked monitoring is a second child task inside `run()`'s task group, polling `getInfo().parkedMessageCount`. Auth is a token-provider closure on the publisher's configuration — the framework never implements an OAuth2 flow, it accepts whatever token the host can produce. `ForwarderGroup` owns the restart-with-backoff loop that hosts currently hand-roll.

**Tech Stack:** Swift 6 strict concurrency. Verified upstream APIs (cite these, do not re-derive): `PersistentSubscriptions<SpecifiedPersistentSubscriptionTarget>.getInfo() -> PersistentSubscription.SubscriptionInfo` (`PersistentSubscriptions+Specified.swift:50`); `SubscriptionInfo.parkedMessageCount: Int64` (`PersistentSubscription.SubscriptionInfo.swift:69`); `PersistentSubscriptions.Nack.Action` includes `.park`; `CreateSettings.maxRetryCount` (`PersistentSubscription.Settings.swift:20`).

## Global Constraints

- **`@unchecked Sendable` is FORBIDDEN.** Mutable-state test doubles are actors.
- No new package dependencies.
- Plain `swift test` green offline (42 today + the new offline tests); integration suites stay env-gated on `PULSAR_HTTP_URL` / `KURRENT_DB_URL`.
- **Every claim about an upstream API in your report must cite `file:line` you actually read.** A prior round of this project shipped a fabricated citation; citations are spot-checked.
- Decisions already made — implement, do not re-litigate: multi-rule re-publish on retry is **accepted** (downstream dedups on `eventId`); the loop stays **strictly sequential** (ordering over throughput). Both must end up documented in the type docs.
- Work on branch `feature/context-forwarder` (PR #7 is open and unmerged — the module should land in its decided shape). Commit after every task with the exact message given. Do not push (the controller pushes).

## File Structure (end state)

```
Sources/ContextForwarder/
  ForwardedRecord.swift        # occurredAt REMOVED; decodeOccurred() added
  ForwardingError.swift        # NEW — ForwardingError + ForwardingDisposition
  ForwardingRule.swift         # doc: permanent-error contract
  ContextForwarder.swift       # park vs retry; MonitoringSettings; parked monitor task
  ForwarderGroup.swift         # NEW — multi-forwarder run with self-heal
  PulsarRESTPublisher.swift    # Authentication on Configuration
Tests/ContextForwarderTests/
  ForwardingErrorTests.swift          # NEW
  ForwardedRecordTests.swift          # NEW (decodeOccurred)
  PulsarAuthTests.swift               # NEW (header building)
Tests/ContextForwarderIntegrationTests/
  ParkedMonitorTests.swift            # NEW (env-gated: permanent error → park → monitor sees it)
```

---

### Task 1: Honest event time + permanent-error classification

**Files:**
- Create: `Sources/ContextForwarder/ForwardingError.swift`
- Modify: `Sources/ContextForwarder/ForwardedRecord.swift`
- Modify: `Sources/ContextForwarder/ForwardingRule.swift` (doc comment only)
- Modify: `Sources/ContextForwarder/ContextForwarder.swift` (run loop's catch)
- Test: `Tests/ContextForwarderTests/ForwardingErrorTests.swift`, `Tests/ContextForwarderTests/ForwardedRecordTests.swift`
- Modify: `Tests/ContextForwarderTests/ForwardingRuleTests.swift` (drop `occurredAt` from fixtures)
- Modify: `Tests/ContextForwarderIntegrationTests/ForwarderLoopTests.swift` (same)

**Interfaces:**
- Produces: `ForwardingError.permanent(reason: String)`; `ForwardingDisposition { retry, park }` + `ForwardingDisposition(for: any Error)`; `ForwardedRecord(eventType:streamName:eventId:data:)` (**no time parameter**), `record.decodeOccurred() throws -> Date`, `record.decodeBody(_:)` now throwing `.permanent` on decode failure.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/ContextForwarderTests/ForwardingErrorTests.swift
import Foundation
import Testing
@testable import ContextForwarder

@Suite("Error classification")
struct ForwardingErrorTests {

    struct Transient: Error {}

    @Test("explicit permanent errors park")
    func permanentParks() {
        #expect(ForwardingDisposition(for: ForwardingError.permanent(reason: "bad payload")) == .park)
    }

    @Test("unknown errors retry — transient is the safe default")
    func unknownRetries() {
        #expect(ForwardingDisposition(for: Transient()) == .retry)
    }

    @Test("decode failures are permanent: a malformed payload never decodes")
    func decodeFailureIsPermanent() {
        struct Body: Decodable { let required: String }
        let record = ForwardedRecord(
            eventType: "X", streamName: "s", eventId: "e",
            data: #"{"other":1}"#.data(using: .utf8)!)

        #expect(throws: ForwardingError.self) { _ = try record.decodeBody(Body.self) }
        do {
            _ = try record.decodeBody(Body.self)
        } catch {
            #expect(ForwardingDisposition(for: error) == .park)
        }
    }
}
```

```swift
// Tests/ContextForwarderTests/ForwardedRecordTests.swift
import Foundation
import Testing
@testable import ContextForwarder

@Suite("ForwardedRecord")
struct ForwardedRecordTests {

    /// DDDKit-generated events encode `occurred` with a plain JSONEncoder
    /// (.deferredToDate → seconds since reference date).
    private func data(occurred: Date) -> Data {
        let seconds = occurred.timeIntervalSinceReferenceDate
        return #"{"occurred":\#(seconds),"who":"acc-1"}"#.data(using: .utf8)!
    }

    @Test("decodeOccurred reads the event's own timestamp")
    func decodesOccurred() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let record = ForwardedRecord(
            eventType: "X", streamName: "s", eventId: "e", data: data(occurred: when))

        let decoded = try record.decodeOccurred()
        #expect(abs(decoded.timeIntervalSince(when)) < 0.001)
    }

    @Test("decodeOccurred throws permanent when the event carries no timestamp")
    func missingOccurredIsPermanent() {
        let record = ForwardedRecord(
            eventType: "X", streamName: "s", eventId: "e",
            data: #"{"who":"acc-1"}"#.data(using: .utf8)!)

        #expect(throws: ForwardingError.self) { _ = try record.decodeOccurred() }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter "ForwardingErrorTests|ForwardedRecordTests" 2>&1 | tail -5`
Expected: FAIL — `cannot find 'ForwardingDisposition'`, and `ForwardedRecord` init still demands `occurredAt`.

- [ ] **Step 3: Create the error module**

```swift
// Sources/ContextForwarder/ForwardingError.swift
import Foundation

/// Errors a rule (or the framework) raises to steer redelivery.
public enum ForwardingError: Error, Equatable {
    /// This record will NEVER forward successfully — a malformed payload, a
    /// missing required field, an event shape the rule cannot handle. Retrying
    /// only delays the inevitable, so the forwarder parks it immediately
    /// instead of burning the retry budget.
    case permanent(reason: String)
}

/// What the forwarder does with a failed record.
public enum ForwardingDisposition: Equatable, Sendable {
    /// Transient: redeliver and try again (the safe default for unknown errors).
    case retry
    /// Permanent: park now. Parked messages stop being delivered — the parked
    /// monitor is what makes them visible.
    case park

    /// Transient unless the error explicitly says otherwise.
    public init(for error: any Error) {
        if error is ForwardingError {
            self = .park
        } else {
            self = .retry
        }
    }
}
```

- [ ] **Step 4: Rewrite ForwardedRecord**

Replace the whole file:

```swift
// Sources/ContextForwarder/ForwardedRecord.swift
import Foundation

/// Kit-agnostic view of one recorded domain event — what a translate closure
/// sees. `data` is the raw JSON payload as stored in KurrentDB.
///
/// Deliberately carries NO timestamp: swift-kurrentdb's `RecordedEvent` has no
/// server-side created-date, so any time this type could offer would be
/// capture time masquerading as event time. Event time must come from the
/// event's own payload — see `decodeOccurred()`.
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

    /// Decodes the payload. A decode failure is `ForwardingError.permanent`:
    /// bytes that don't fit the shape today won't fit on redelivery either.
    public func decodeBody<T: Decodable>(_ type: T.Type) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ForwardingError.permanent(
                reason: "decoding \(T.self) from \(eventType) (\(eventId)) failed: \(error)")
        }
    }

    /// Reads the event's own `occurred` timestamp — every DDDKit-generated
    /// `DomainEvent` carries one, encoded with a plain `JSONEncoder`
    /// (`.deferredToDate`), which is why this uses a matching plain decoder.
    /// Throws `.permanent` when absent: an event with no time will never grow
    /// one on redelivery.
    public func decodeOccurred() throws -> Date {
        struct TimeEnvelope: Decodable { let occurred: Date }
        do {
            return try JSONDecoder().decode(TimeEnvelope.self, from: data).occurred
        } catch {
            throw ForwardingError.permanent(
                reason: "\(eventType) (\(eventId)) carries no decodable `occurred`: \(error)")
        }
    }
}
```

- [ ] **Step 5: Wire disposition into the run loop**

In `ContextForwarder.run()`'s catch block, replace the unconditional `.retry` with:

```swift
            } catch {
                switch ForwardingDisposition(for: error) {
                case .park:
                    logger.error("forwarding permanently failed, parking: \(error)")
                    try await subscription.nack(readEvents: event, action: .park, reason: "\(error)")
                case .retry:
                    logger.error("forwarding failed, will retry: \(error)")
                    try await subscription.nack(readEvents: event, action: .retry, reason: "\(error)")
                }
            }
```

Also delete the `ForwardedRecord.init(from event: ReadEvent)` extension's `occurredAt:` argument (it no longer exists) and drop the long adaptation note about the missing timestamp — that reasoning now lives on `ForwardedRecord` itself. Keep the `.record`-vs-`.link` note.

On `ForwardingRule`'s doc comment, append:

```swift
/// Throwing `ForwardingError.permanent` parks the record instead of retrying —
/// use it for payloads that can never translate. Any other error is treated as
/// transient and redelivered.
```

- [ ] **Step 6: Update the existing fixtures**

`ForwardingRuleTests.swift` and `ForwarderLoopTests.swift` construct `ForwardedRecord(...)` with `occurredAt:` and build PL events from `record.occurredAt`. Drop the argument; for the PL event's `occurredAt`, use `try record.decodeOccurred()` where the fixture's JSON has an `occurred` field, otherwise add one to the fixture JSON. Keep every existing assertion's intent intact.

- [ ] **Step 7: Verify + commit**

Run: `swift test 2>&1 | tail -2` (offline green, integration skipped), then
`PULSAR_HTTP_URL="http://localhost:8081" KURRENT_DB_URL="kurrentdb://localhost:2113?tls=false" swift test --filter ContextForwarderIntegrationTests 2>&1 | tail -2`

```bash
git add Sources/ContextForwarder Tests/ContextForwarderTests Tests/ContextForwarderIntegrationTests
git commit -m "feat: enforce event time from payload; park permanently-failing records"
```

---

### Task 2: Built-in parked-message monitoring

**Files:**
- Modify: `Sources/ContextForwarder/ContextForwarder.swift`
- Test: `Tests/ContextForwarderIntegrationTests/ParkedMonitorTests.swift`

**Interfaces:**
- Produces: `ContextForwarder.MonitoringSettings { parkedCheckInterval: Duration?, onParkedDetected: (@Sendable (Int64) async -> Void)? }` (init param `monitoring:` on `ContextForwarder`, defaulting to a 60s check that logs at error level); `SubscriptionSettings.maxRetryCount: Int32` (default 10, mirroring the server default) so hosts and tests can bound the retry budget.

- [ ] **Step 1: Extend the settings**

In `ContextForwarder`, add to `SubscriptionSettings`:

```swift
        /// Deliveries attempted before the server parks the message. Mirrors
        /// KurrentDB's own default; lower it when a rule's failures are cheap
        /// to diagnose and expensive to retry.
        public var maxRetryCount: Int32 = 10
```

and apply it in `ensureSubscription()` alongthe existing settings (`$0.settings.maxRetryCount = subscriptionSettings.maxRetryCount` — verify the exact property name at `PersistentSubscription.Settings.swift:20` and cite it).

Add the monitoring settings type and stored property:

```swift
    /// Parked messages stop being delivered silently — nothing throws, nothing
    /// logs, the downstream simply never receives those events. This poll is
    /// the only thing that makes that visible.
    public struct MonitoringSettings: Sendable {
        /// nil disables the poll entirely.
        public var parkedCheckInterval: Duration? = .seconds(60)
        /// Called with the parked count whenever it is greater than zero.
        /// Defaults to an error-level log line.
        public var onParkedDetected: (@Sendable (Int64) async -> Void)?
        public init() {}
    }
```

Thread `monitoring: MonitoringSettings = .init()` through `init` and `register` (same immutable-copy pattern as the other stored properties).

- [ ] **Step 2: Split run() into a task group**

Restructure `run()` so the event loop moves into a private method and `run()` supervises both children:

```swift
    /// Consumes until cancelled, while polling for parked messages in
    /// parallel. Either child throwing cancels the other.
    public func run() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.consume() }
            if let interval = monitoring.parkedCheckInterval {
                group.addTask { try await self.pollParked(every: interval) }
            }
            // Surface the first failure and tear the sibling down with it.
            try await group.next()
            group.cancelAll()
        }
    }

    private func pollParked(every interval: Duration) async throws {
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return }
            do {
                let info = try await client.persistentSubscriptions(stream: stream, group: groupName).getInfo()
                let parked = info.parkedMessageCount
                guard parked > 0 else { continue }
                if let onParkedDetected = monitoring.onParkedDetected {
                    await onParkedDetected(parked)
                } else {
                    logger.error("\(parked) parked message(s) on \(stream)/\(groupName) — those events are NOT reaching the backbone")
                }
            } catch {
                // A failed poll must never take the forwarder down.
                logger.warning("parked-message check failed: \(error)")
            }
        }
    }
```

(`consume()` is the existing loop body verbatim. Verify `getInfo()`'s exact spelling/return at `PersistentSubscriptions+Specified.swift:50` and `parkedMessageCount` at `PersistentSubscription.SubscriptionInfo.swift:69`; cite both.)

- [ ] **Step 3: Env-gated integration test — permanent error parks, monitor sees it**

```swift
// Tests/ContextForwarderIntegrationTests/ParkedMonitorTests.swift
import Foundation
import KurrentDB
import Testing
@testable import ContextForwarder

/// Records parked-count callbacks; actor-isolated (no @unchecked Sendable).
actor ParkedRecorder {
    private(set) var counts: [Int64] = []
    func record(_ count: Int64) { counts.append(count) }
    var sawParked: Bool { counts.contains { $0 > 0 } }
}

/// Never publishes — this suite is about the failure path.
actor UnusedPublisher: PublishedLanguagePublisher {
    func publish(_ event: PublishedLanguageEvent) async throws {
        preconditionFailure("this suite's rule always fails before publishing")
    }
}

@Suite("Parked monitoring", .serialized, .enabled(if: IntegrationEnvironment.fullEnabled))
struct ParkedMonitorTests {

    @Test("a permanently-failing rule parks the record and the monitor reports it")
    func permanentFailureIsParkedAndReported() async throws {
        let kurrentURL = try #require(IntegrationEnvironment.kurrentURL)
        let settings: ClientSettings = try kurrentURL.parse()
        let client = KurrentDBClient(settings: settings)

        let suffix = UUID().uuidString.prefix(8).lowercased()
        let category = "ParkTest\(suffix)"
        let group = "parked-monitor-test-\(suffix)"
        let recorder = ParkedRecorder()

        var subscriptionSettings = ContextForwarder.SubscriptionSettings()
        subscriptionSettings.startFrom = .start        // the seed is appended first
        subscriptionSettings.maxRetryCount = 1         // park fast
        var monitoring = ContextForwarder.MonitoringSettings()
        monitoring.parkedCheckInterval = .milliseconds(300)
        monitoring.onParkedDetected = { count in await recorder.record(count) }

        let forwarder = ContextForwarder(
            client: client,
            publisher: UnusedPublisher(),
            stream: "$ce-\(category)",
            groupName: group,
            subscriptionSettings: subscriptionSettings,
            monitoring: monitoring
        ).register(ForwardingRule(eventTypes: ["Unparseable"]) { record in
            // Body doesn't match — decodeBody throws .permanent.
            struct Expected: Decodable { let required: String }
            _ = try record.decodeBody(Expected.self)
            return nil
        })

        try await forwarder.ensureSubscription()
        struct Seed: Codable { let unexpected: String }
        try await client.streams(specified: "\(category)-one").append(events: [
            EventData(eventType: "Unparseable", model: Seed(unexpected: "shape"))
        ])

        let runner = Task { try? await forwarder.run() }
        defer { runner.cancel() }

        var sawParked = false
        for _ in 0..<60 {
            if await recorder.sawParked { sawParked = true; break }
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect(sawParked)

        runner.cancel()
        _ = try? await client.persistentSubscriptions(stream: "$ce-\(category)", group: group).delete()
        _ = try? await client.streams(specified: "\(category)-one").delete { $0.expectedRevision = .any }
    }
}
```

(Adapt `EventData`'s initializer and the delete calls to the actual API as the existing loop test does.)

- [ ] **Step 4: Verify + commit**

Offline green; live: `PULSAR_HTTP_URL=... KURRENT_DB_URL=... swift test --filter ParkedMonitorTests` — run it **twice** consecutively (fresh category each run, so both must pass).

```bash
git add Sources/ContextForwarder Tests/ContextForwarderIntegrationTests
git commit -m "feat: poll for parked messages so silent forwarding loss becomes visible"
```

---

### Task 3: Pulsar authentication

**Files:**
- Modify: `Sources/ContextForwarder/PulsarRESTPublisher.swift`
- Test: `Tests/ContextForwarderTests/PulsarAuthTests.swift`

**Interfaces:**
- Produces: `PulsarRESTPublisher.Authentication { none, token(String), tokenProvider(@Sendable () async throws -> String) }`; `Configuration(baseURL:tenant:namespace:topic:authentication:)` (authentication defaults to `.none`); internal `authorizationHeader() async throws -> String?` for testability.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/ContextForwarderTests/PulsarAuthTests.swift
import Foundation
import Testing
@testable import ContextForwarder

@Suite("Pulsar authentication")
struct PulsarAuthTests {

    private func config(_ auth: PulsarRESTPublisher.Authentication) -> PulsarRESTPublisher.Configuration {
        .init(baseURL: "http://localhost:8081", topic: "t", authentication: auth)
    }

    @Test("no auth sends no header")
    func noneSendsNothing() async throws {
        #expect(try await config(.none).authorizationHeader() == nil)
    }

    @Test("static token becomes a bearer header")
    func staticToken() async throws {
        #expect(try await config(.token("abc")).authorizationHeader() == "Bearer abc")
    }

    @Test("provider is called per request — rotating tokens stay fresh")
    func providerCalledEachTime() async throws {
        let counter = CallCounter()
        let configuration = config(.tokenProvider { await counter.next() })

        #expect(try await configuration.authorizationHeader() == "Bearer token-1")
        #expect(try await configuration.authorizationHeader() == "Bearer token-2")
    }

    @Test("provider failures surface to the caller")
    func providerThrows() async {
        struct Boom: Error {}
        let configuration = config(.tokenProvider { throw Boom() })
        await #expect(throws: Boom.self) { _ = try await configuration.authorizationHeader() }
    }
}

actor CallCounter {
    private var count = 0
    func next() -> String { count += 1; return "token-\(count)" }
}
```

- [ ] **Step 2: Run to verify failure, then implement**

In `PulsarRESTPublisher`:

```swift
    /// How to authenticate to the broker. The framework never implements an
    /// OAuth2 flow itself — `tokenProvider` accepts whatever the host can
    /// produce (a cached client-credentials token, a rotating file, a vault
    /// lookup) and is invoked per request so rotation just works.
    public enum Authentication: Sendable {
        case none
        case token(String)
        case tokenProvider(@Sendable () async throws -> String)
    }
```

Add `public let authentication: Authentication` to `Configuration` with an `authentication: Authentication = .none` parameter (keep it LAST so existing call sites keep compiling), and:

```swift
        func authorizationHeader() async throws -> String? {
            switch authentication {
            case .none: return nil
            case .token(let token): return "Bearer \(token)"
            case .tokenProvider(let provide): return "Bearer \(try await provide())"
            }
        }
```

Apply it in **both** `ensureTopic()` and `publish(_:)`, right after setting the method:

```swift
        if let authorization = try await configuration.authorizationHeader() {
            request.headers.add(name: "Authorization", value: authorization)
        }
```

- [ ] **Step 3: Verify + commit**

Offline green (4 new tests); live `PulsarPublisherTests` still green (unauthenticated local broker exercises the `.none` path end to end).

```bash
git add Sources/ContextForwarder/PulsarRESTPublisher.swift Tests/ContextForwarderTests/PulsarAuthTests.swift
git commit -m "feat: bearer-token authentication for the Pulsar REST publisher"
```

---

### Task 4: ForwarderGroup + record the accepted trade-offs

**Files:**
- Create: `Sources/ContextForwarder/ForwarderGroup.swift`
- Modify: `Sources/ContextForwarder/ContextForwarder.swift` (doc comments for the two accepted trade-offs)

**Interfaces:**
- Produces: `ForwarderGroup(forwarders:restartDelay:logger:)`, `ensureAll() async throws`, `run() async throws` — one child task per forwarder, each restarting with backoff on either a throw or a clean stream end, isolated from its siblings.

- [ ] **Step 1: Implement the group**

```swift
// Sources/ContextForwarder/ForwarderGroup.swift
import Foundation
import Logging

/// Runs several forwarders side by side — one per source stream, each with its
/// own subscription group and checkpoint, so a stuck or failing stream cannot
/// stall the others.
///
/// Owns the restart loop hosts would otherwise hand-roll: a forwarder's `run()`
/// returns normally when the server closes the subscription stream cleanly
/// (idle timeout, broker restart, load-balancer reset), which is indistinguishable
/// from "done" at the call site — so BOTH exits back off and re-subscribe.
public struct ForwarderGroup: Sendable {
    private let forwarders: [ContextForwarder]
    private let restartDelay: Duration
    private let logger: Logger

    public init(
        forwarders: [ContextForwarder],
        restartDelay: Duration = .seconds(5),
        logger: Logger = Logger(label: "ForwarderGroup")
    ) {
        self.forwarders = forwarders
        self.restartDelay = restartDelay
        self.logger = logger
    }

    /// Idempotent setup for every member. Throws on the first genuine failure
    /// so a host's startup gate can refuse to serve with a broken forwarder.
    public func ensureAll() async throws {
        for forwarder in forwarders {
            try await forwarder.ensureSubscription()
        }
    }

    /// Runs until cancelled. Never returns normally while any member remains.
    public func run() async throws {
        await withTaskGroup(of: Void.self) { group in
            for forwarder in forwarders {
                group.addTask { [restartDelay, logger] in
                    while !Task.isCancelled {
                        do {
                            try await forwarder.run()
                            logger.warning("forwarder stream ended cleanly — restarting in \(restartDelay)")
                        } catch {
                            logger.error("forwarder stopped: \(error) — restarting in \(restartDelay)")
                        }
                        if Task.isCancelled { return }
                        try? await Task.sleep(for: restartDelay)
                    }
                }
            }
        }
    }
}
```

(If `ContextForwarder` needs to expose its `stream`/`groupName` for the log lines, add read-only `public var`s rather than reaching into privates — note whichever you do.)

- [ ] **Step 2: Document the two accepted trade-offs**

On `ContextForwarder`'s type doc comment, append these paragraphs (they record rulings, so keep the wording):

```swift
/// **Ack granularity is per delivery, not per rule** (accepted trade-off): if
/// one record matches several rules and a later rule fails, the whole record is
/// redelivered and the earlier rules publish again. Consumers dedup on
/// `eventId`, which absorbs it.
///
/// **The loop is strictly sequential** (accepted trade-off): one record at a
/// time, so throughput is bounded by translate + publish latency. Ordering
/// within the source stream is preserved, which is the property worth keeping;
/// revisit only if a high-frequency stream ever needs forwarding.
```

- [ ] **Step 3: Verify + commit**

`swift build --build-tests` green; full offline suite green; live suites green.

```bash
git add Sources/ContextForwarder
git commit -m "feat: ForwarderGroup runs and self-heals multiple forwarders"
```

---

## Out of Scope

- OC's mount (`OpportunityContext` branch `feature/pl-forwarder`) still depends on the standalone package and uses `record.occurredAt`; migrating it to the kit module + `decodeOccurred()` waits on the human's routing decision.
- Parked-message *replay* (KurrentDB's replayParked) — monitoring first, remediation tooling later.
- Real OAuth2 client-credentials implementation (the token provider is the seam; hosts bring their own flow).

## Follow-ups from final review

- **設計變更(在七項裁決之上追加,需 owner 確認):** `.park` 的引入產生了原本不存在的靜默遺失路徑——同一筆事件若前面的 rule 永久失敗,後面的 rule 因為 park 不再投遞而永遠沒機會執行。已改為**逐一嘗試所有命中的 rule、收集失敗後才決定單一 disposition**,優先序 `任一暫時性 → retry`(給暫時性的那條再一次機會;永久性的只是再失敗一次,由 maxRetryCount 收斂)`否則任一永久性 → park`,`皆無失敗 → ack`。若你偏好別的取捨(例如限制「一個事件型別只准一條 rule」),說一聲即可改。
- ack() 失敗現在會傳出 `consume()`(先前是 nack-then-continue)。現實情境下 ack 失敗代表連線已斷,下一次迭代本來就會拋錯,由 host 的重啟迴圈接手;列為已知的行為變更。
- OC 掛載遷到 kit 內建模組時,需一併讀 `ForwardedRecord` 的說明(事件時間改由 payload 取)與上述多 rule/park 互動。
- `ForwarderGroupTests` 的 `>=3` 下界在高負載 CI 有約 40% 餘裕,理論上可能 flake;真的發生時把視窗拉長即可。
