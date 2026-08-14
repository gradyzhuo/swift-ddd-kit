# ContextReceiver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give swift-ddd-kit a Pulsar consume side symmetric to `ContextForwarder`, so a downstream context can subscribe to Published Language events over Pulsar's WebSocket protocol with at-least-once delivery, real backpressure, and DLQ monitoring.

**Architecture:** Three new targets. `PublishedLanguage` holds the wire vocabulary shared by both directions (zero dependencies). `ContextReceiver` holds all protocol logic — frame decoding, disposition rules, permit accounting, the runner loop — behind a `PulsarMessageSource` abstraction, so it is fully unit-testable offline and builds on every platform. `ContextReceiverWebSocket` is the one concrete transport, built on `hummingbird-project/swift-websocket`; it is the only target that cannot compile on macOS (see Global Constraints).

**Tech Stack:** Swift 6 strict concurrency, `hummingbird-project/swift-websocket` (product `WSClient`, 1.6.1), AsyncHTTPClient (already present, used for the DLQ admin probe), swift-log.

**Spec:** This plan's `Design Reference` section below, plus `/Volumes/Development/NotificationContext/docs/decisions/2026-08-09-productionization-decisions.md` (the decision ledger this work descends from) and `docs/superpowers/plans/2026-08-13-forwarder-hardening.md` (the seven hardening rulings, which this plan mirrors on the consume side).

## Global Constraints

- **No `@unchecked Sendable`, no `nonisolated(unsafe)` in our own code.** Use actors or `Sendable` value types. This is a standing project rule, not a preference.
- **`swift-websocket` is pinned to the official upstream `from: "1.6.1"`.** It does not compile on the macOS 26 SDK (upstream bug: `Sources/WSCore/WebSocketOutboundWriter.swift:210` declares `extension ByteBuffer { init(_uint8Span: Span<UInt8>) }` guarded only by `#if compiler(>=6.2)`, with no `@available`; the call site at `:83` is guarded but the helper is not). Verified: fails on macOS 26 for tags 1.4.0/1.5.0/1.6.0/1.6.1; **builds clean on Linux Swift 6.2.4** (`swift:6.2-noble`, exit 0).
- **Therefore `ContextReceiverWebSocket` is developed and tested on Linux only**, via `docker run --rm -v $PWD:/src -w /src swift:6.2-noble`. Do not add a `swift-websocket` dependency to any target other than `ContextReceiverWebSocket`.
- **The macOS breakage must stay contained to that one target.** Its `WSClient` dependency is declared `condition: .when(platforms: [.linux])` and its source body sits inside `#if os(Linux)`, so on macOS the module compiles empty rather than failing. `swift build` and `swift test` must both still succeed on macOS after every task in this plan — including Tasks 7 and 8. A whole-package build failure would hit every consumer of swift-ddd-kit, not just this module.
- **Wire compatibility is not optional.** `PublishedLanguageEvent` may only gain *optional* fields. An event written by the current forwarder must decode unchanged after Task 1.
- **All credentials via environment variables**, never in the repo, never in test fixtures.
- **Branch:** `feature/context-forwarder` (this work is folded into the existing open PR #7, per the owner's decision).
- **Commit author:** `Grady Zhuo <gradyzhuo@gmail.com>`.

---

## Design Reference

### The Pulsar WebSocket consumer protocol (verified against apache.org docs, two independent fetches agreeing)

Endpoint:

```
ws://{host}:8080/ws/v2/consumer/persistent/{tenant}/{namespace}/{topic}/{subscription}
```

Query parameters we use:

| Parameter | Value we send | Why |
|---|---|---|
| `subscriptionType` | `Key_Shared` | Per-key ordering with multi-consumer scale-out |
| `pullMode` | `true` | We issue permits ourselves — real backpressure |
| `maxRedeliverCount` | host-configured | Poison messages go to DLQ instead of looping |
| `deadLetterTopic` | host-configured | Explicit, rather than the `{topic}-{subscription}-DLQ` default |
| `negativeAckRedeliveryDelay` | host-configured (ms) | Transient-failure backoff |
| `consumerName` | host-configured | Observability on the broker side |

Auth is an `Authorization` header on the handshake, **not** the `token` query parameter — query strings land in broker access logs.

Incoming frame (JSON text frame):

```json
{
  "messageId": "CAAQAw==",
  "payload": "eyJldmVudElkIjoi...",
  "publishTime": "2026-08-14T01:02:03.000Z",
  "redeliveryCount": 0,
  "properties": {"eventType": "OpportunityCollaboratorAdded.v1"},
  "key": "opportunity-123"
}
```

`payload` is **base64-encoded** on the consume side, even though the REST produce side accepts a raw string. This asymmetry is real and is the single most likely source of a silent end-to-end failure; Task 3 tests it directly and Task 8 proves it against a live broker.

Frames we send:

```json
{"messageId": "CAAQAw=="}                                  // ack
{"type": "negativeAcknowledge", "messageId": "CAAQAw=="}    // nack
{"type": "permit", "permitMessages": 100}                   // flow control
```

### swift-websocket API (verified against tag 1.6.1 source)

```swift
// Sources/WSClient/WebSocketClient.swift:243
WebSocketClient.connect(
    url: String,
    configuration: WebSocketClientConfiguration = .init(),  // .additionalHeaders: HTTPFields, .autoPing: AutoPingSetup
    tlsConfiguration: TLSConfiguration? = nil,
    eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
    logger: Logger,
    handler: @escaping WebSocketDataHandler<Context>
) async throws -> WebSocketCloseFrame?

// Sources/WSCore/WebSocketDataHandler.swift:10
public typealias WebSocketDataHandler<Context: WebSocketContext> =
    @Sendable (WebSocketInboundStream, WebSocketOutboundWriter, Context) async throws -> Void

// Sources/WSCore/WebSocketInboundMessageStream.swift:41
inbound.messages(maxSize: Int) -> WebSocketInboundMessageStream   // Element == WebSocketMessage (.text/.binary)

// Sources/WSCore/WebSocketOutboundWriter.swift:79
outbound.writeTextMessage(_ string: String) async throws

// Sources/WSCore/WebSocketHandler.swift:35
AutoPingSetup.enabled(timePeriod: Duration)
```

### Delivery semantics

At-least-once. ACK is sent **only after** the host handler returns successfully. On a transient error we NACK (Pulsar redelivers after `negativeAckRedeliveryDelay`). On a permanent error we ACK-and-drop only if the host explicitly says so; otherwise we NACK and let `maxRedeliverCount` route the message to the DLQ — the Pulsar equivalent of `ContextForwarder`'s `.park`, matching hardening ruling #2. Duplicate suppression is the host's responsibility (deterministic aggregate ids); the runner surfaces `redeliveryCount` so the host can tell a retry from a first attempt.

### File structure

```
Sources/PublishedLanguage/                 (new target, zero deps)
  PublishedLanguageEvent.swift             moved from ContextForwarder, + partitionKey

Sources/ContextForwarder/                  (existing target, now depends on PublishedLanguage)
  PulsarRESTPublisher.swift                key := partitionKey ?? eventId; adds eventTime

Sources/ContextReceiver/                   (new target: PublishedLanguage, AsyncHTTPClient, Logging)
  ConsumerFrame.swift                      inbound frame decoding + base64 payload
  ReceivedRecord.swift                     decoded event + delivery metadata
  ReceiveDisposition.swift                 ack / nack / dropToDLQ, mirrors ForwardingDisposition
  PulsarMessageSource.swift                transport protocol + settle callback
  PublishedLanguageHandler.swift           host-implemented consume port
  ContextReceiver.swift                    the runner: source -> handler -> settle, permit accounting
  DeadLetterMonitor.swift                  periodic DLQ backlog probe + alert callback

Sources/ContextReceiver/
  ConsumerEndpoint.swift                   endpoint + query-parameter builder (pure, portable tests)

Sources/ContextReceiverWebSocket/          (new target: ContextReceiver, WSClient) — LINUX ONLY
  WebSocketMessageSource.swift             the real transport, reconnect with backoff
                                           (whole file body inside #if os(Linux))

Tests/ContextReceiverTests/                (portable, offline — must pass on macOS)
  ConsumerFrameTests.swift
  ContextReceiverTests.swift
  DeadLetterMonitorTests.swift
  ConsumerURLTests.swift                   (URL builder is duplicated as a portable copy; see Task 7)

Tests/ContextReceiverIntegrationTests/     (env-gated, Linux)
  LivePulsarTests.swift
```

---

### Task 1: Shared `PublishedLanguage` target with an additive `partitionKey`

**Files:**
- Create: `Sources/PublishedLanguage/PublishedLanguageEvent.swift` (moved from `Sources/ContextForwarder/PublishedLanguageEvent.swift`)
- Modify: `Package.swift` — add `PublishedLanguage` target + library product; make `ContextForwarder` depend on it
- Modify: `Sources/ContextForwarder/PublishedLanguagePublisher.swift` — add `import PublishedLanguage`
- Test: `Tests/ContextForwarderTests/PublishedLanguageEventTests.swift`

**Interfaces:**
- Produces: `PublishedLanguageEvent` with existing fields (`eventId: String`, `eventType: String`, `occurredAt: Date`, `recipientIds: [String]`, `payload: [String: String]`) plus `partitionKey: String?`; `static var wireEncoder: JSONEncoder`; new `static var wireDecoder: JSONDecoder`; `var effectivePartitionKey: String`.
- Consumes: nothing.

- [ ] **Step 1: Write the failing wire-compatibility test**

```swift
import Foundation
import Testing
@testable import PublishedLanguage

@Suite("PublishedLanguageEvent wire format")
struct PublishedLanguageEventTests {
    /// An event written by the pre-partitionKey forwarder must still decode.
    @Test func decodesLegacyPayloadWithoutPartitionKey() throws {
        let legacy = """
        {"eventId":"e-1","eventType":"OpportunityCollaboratorAdded.v1",\
        "occurredAt":"2026-08-14T01:02:03Z","recipientIds":["u-1"],\
        "payload":{"opportunityId":"o-1"}}
        """
        let event = try PublishedLanguageEvent.wireDecoder.decode(
            PublishedLanguageEvent.self, from: Data(legacy.utf8)
        )
        #expect(event.eventId == "e-1")
        #expect(event.partitionKey == nil)
        #expect(event.effectivePartitionKey == "e-1")
    }

    @Test func effectivePartitionKeyPrefersExplicitKey() {
        let event = PublishedLanguageEvent(
            eventId: "e-1",
            eventType: "T.v1",
            occurredAt: Date(timeIntervalSince1970: 0),
            recipientIds: ["u-1"],
            payload: [:],
            partitionKey: "opportunity-123"
        )
        #expect(event.effectivePartitionKey == "opportunity-123")
    }

    /// Absent partitionKey must not appear in the encoded bytes at all,
    /// so existing consumers see a byte-identical wire format.
    @Test func omitsNilPartitionKeyFromEncodedForm() throws {
        let event = PublishedLanguageEvent(
            eventId: "e-1", eventType: "T.v1",
            occurredAt: Date(timeIntervalSince1970: 0),
            recipientIds: [], payload: [:]
        )
        let json = try PublishedLanguageEvent.wireEncoder.encode(event)
        #expect(!String(decoding: json, as: UTF8.self).contains("partitionKey"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter PublishedLanguageEventTests`
Expected: FAIL — `no such module 'PublishedLanguage'`.

- [ ] **Step 3: Create the target and move the type**

`git mv Sources/ContextForwarder/PublishedLanguageEvent.swift Sources/PublishedLanguage/PublishedLanguageEvent.swift`, then add to the moved file:

```swift
    /// Pulsar partition key. `Key_Shared` guarantees ordering per key, so hosts
    /// that need per-aggregate ordering set this to the aggregate id. Optional
    /// for wire compatibility; falls back to `eventId`, which yields a unique
    /// key per message and therefore no ordering guarantee.
    public let partitionKey: String?

    /// The key actually sent to Pulsar.
    public var effectivePartitionKey: String { partitionKey ?? eventId }

    public static let wireDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
```

Add `partitionKey: String? = nil` as the last parameter of the existing `public init`, defaulted so no existing call site breaks. Confirm `wireEncoder` does not set `.sortedKeys`-incompatible options and that `JSONEncoder` omits nil optionals by default (it does — no `encodeIfPresent` override needed).

In `Package.swift`, add the product and target, and wire the dependency:

```swift
.library(name: "PublishedLanguage", targets: ["PublishedLanguage"]),
```

```swift
.target(name: "PublishedLanguage"),
.target(
    name: "ContextForwarder",
    dependencies: [
        "PublishedLanguage",
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        // ...keep every existing dependency exactly as it is
    ]
),
```

Add `import PublishedLanguage` to every file in `Sources/ContextForwarder/` that references `PublishedLanguageEvent`. Find them with `grep -rl PublishedLanguageEvent Sources/ContextForwarder/`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PublishedLanguageEventTests` → PASS (3 tests).
Run: `swift build` → must still succeed on macOS. If `ContextForwarderTests` referenced the type via `@testable import ContextForwarder`, add `import PublishedLanguage` there too.
Run: `swift test --filter ContextForwarderTests` → all pre-existing tests still pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/PublishedLanguage Sources/ContextForwarder Package.swift Tests/ContextForwarderTests
git commit -m "refactor: extract PublishedLanguage target, add optional partitionKey"
```

---

### Task 2: Publisher sends the partition key and Pulsar `eventTime`

**Files:**
- Modify: `Sources/ContextForwarder/PulsarRESTPublisher.swift:76-90` (the `publish(_:)` envelope)
- Test: `Tests/ContextForwarderTests/PulsarRESTPublisherBodyTests.swift`

**Interfaces:**
- Consumes: `PublishedLanguageEvent.effectivePartitionKey` from Task 1.
- Produces: `PulsarRESTPublisher.produceBody(for:) throws -> Data` — extracted from `publish` so the envelope is testable without a broker. `publish` calls it.

**Why:** the current envelope sends `"key": event.eventId`, which is unique per message and therefore defeats `Key_Shared` ordering entirely. It also omits `eventTime`, so the broker stamps its own receive time and the domain occurrence time is only visible inside the payload — losing it for broker-side tooling and TTL. `eventTime` is a documented REST produce field (millisecond epoch).

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
import PublishedLanguage
@testable import ContextForwarder

@Suite("Pulsar REST produce envelope")
struct PulsarRESTPublisherBodyTests {
    private func envelope(_ event: PublishedLanguageEvent) throws -> [String: Any] {
        let data = try PulsarRESTPublisher.produceBody(for: event)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func message(_ event: PublishedLanguageEvent) throws -> [String: Any] {
        let messages = try envelope(event)["messages"] as! [[String: Any]]
        return messages[0]
    }

    @Test func usesPartitionKeyAsPulsarKey() throws {
        let event = PublishedLanguageEvent(
            eventId: "e-1", eventType: "T.v1",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            recipientIds: ["u-1"], payload: [:], partitionKey: "opportunity-123"
        )
        #expect(try message(event)["key"] as? String == "opportunity-123")
    }

    @Test func fallsBackToEventIdWhenNoPartitionKey() throws {
        let event = PublishedLanguageEvent(
            eventId: "e-1", eventType: "T.v1",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            recipientIds: [], payload: [:]
        )
        #expect(try message(event)["key"] as? String == "e-1")
    }

    @Test func sendsOccurredAtAsMillisecondEventTime() throws {
        let event = PublishedLanguageEvent(
            eventId: "e-1", eventType: "T.v1",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            recipientIds: [], payload: [:]
        )
        #expect(try message(event)["eventTime"] as? Int64 == 1_700_000_000_000)
    }

    /// The payload must stay a raw JSON string, not base64: the REST produce
    /// endpoint encodes server-side. (The WS consume side returns base64 —
    /// that asymmetry is deliberate and is handled in ContextReceiver.)
    @Test func payloadIsRawJSONString() throws {
        let event = PublishedLanguageEvent(
            eventId: "e-1", eventType: "T.v1",
            occurredAt: Date(timeIntervalSince1970: 0),
            recipientIds: [], payload: ["k": "v"]
        )
        let payload = try message(event)["payload"] as! String
        #expect(payload.hasPrefix("{"))
        #expect(payload.contains("\"eventId\":\"e-1\""))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter PulsarRESTPublisherBodyTests`
Expected: FAIL — `produceBody` does not exist.

- [ ] **Step 3: Extract and correct the envelope**

Replace the body-building portion of `publish(_:)` in `Sources/ContextForwarder/PulsarRESTPublisher.swift` with:

```swift
    /// Builds the REST produce envelope. `internal` so tests can assert the
    /// wire shape without a live broker.
    static func produceBody(for event: PublishedLanguageEvent) throws -> Data {
        let payloadJSON = try PublishedLanguageEvent.wireEncoder.encode(event)
        guard let payloadString = String(data: payloadJSON, encoding: .utf8) else {
            throw PublishError.encodingFailed
        }
        let envelope: [String: Any] = [
            "messages": [[
                // Raw string, not base64: the REST endpoint encodes server-side.
                "payload": payloadString,
                // Key_Shared orders per key, so this must be the aggregate id
                // when the host wants ordering — not the per-message eventId.
                "key": event.effectivePartitionKey,
                "eventTime": Int64(event.occurredAt.timeIntervalSince1970 * 1000),
                "properties": ["eventType": event.eventType],
            ]]
        ]
        return try JSONSerialization.data(withJSONObject: envelope)
    }

    public func publish(_ event: PublishedLanguageEvent) async throws {
        let body = try Self.produceBody(for: event)
        var request = HTTPClientRequest(url: configuration.producePath)
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        if let authorization = try await configuration.authorizationHeader() {
            request.headers.add(name: "Authorization", value: authorization)
        }
        request.body = .bytes(ByteBuffer(bytes: body))
        // ...keep the existing response handling below unchanged
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PulsarRESTPublisherBodyTests` → PASS (4 tests).
Run: `swift test --filter ContextForwarderTests` → no regressions.

- [ ] **Step 5: Commit**

```bash
git add Sources/ContextForwarder/PulsarRESTPublisher.swift Tests/ContextForwarderTests/PulsarRESTPublisherBodyTests.swift
git commit -m "fix: send aggregate partition key and eventTime on produce"
```

---

### Task 3: Inbound frame decoding

**Files:**
- Create: `Sources/ContextReceiver/ConsumerFrame.swift`
- Create: `Sources/ContextReceiver/ReceivedRecord.swift`
- Modify: `Package.swift` — add `ContextReceiver` target + product, and the test target
- Test: `Tests/ContextReceiverTests/ConsumerFrameTests.swift`

**Interfaces:**
- Consumes: `PublishedLanguageEvent`, `PublishedLanguageEvent.wireDecoder` (Task 1).
- Produces:
  - `struct ConsumerFrame: Sendable` — `messageId: String`, `payload: String`, `publishTime: String?`, `redeliveryCount: Int` (defaults to 0 when absent), `properties: [String: String]`, `key: String?`; `init(json: Data) throws`; `func decodedEvent() throws -> PublishedLanguageEvent`.
  - `struct ReceivedRecord: Sendable` — `event: PublishedLanguageEvent`, `messageId: String`, `redeliveryCount: Int`, `key: String?`, `properties: [String: String]`; `var isRedelivery: Bool`.
  - `enum ReceiveError: Error, Equatable, Sendable` — `.malformedFrame(String)`, `.payloadNotBase64`, `.payloadNotDecodable(String)`, `.adminProbeFailed(String)` (used by Task 6), `.transportUnavailable(String)` (used by Task 7). The last two are declared here, where the type is born, so later tasks do not overload `.malformedFrame` for conditions that have no frame — which would also mis-route through `ReceiveDisposition(for:)`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
import PublishedLanguage
@testable import ContextReceiver

@Suite("Consumer frame decoding")
struct ConsumerFrameTests {
    private func frameJSON(payload: String, redeliveryCount: String = "0") -> Data {
        Data("""
        {"messageId":"CAAQAw==","payload":"\(payload)",\
        "publishTime":"2026-08-14T01:02:03.000Z","redeliveryCount":\(redeliveryCount),\
        "properties":{"eventType":"T.v1"},"key":"opportunity-123"}
        """.utf8)
    }

    private var eventPayloadBase64: String {
        let json = """
        {"eventId":"e-1","eventType":"T.v1","occurredAt":"2026-08-14T01:02:03Z",\
        "recipientIds":["u-1"],"payload":{"opportunityId":"o-1"}}
        """
        return Data(json.utf8).base64EncodedString()
    }

    @Test func decodesFrameFields() throws {
        let frame = try ConsumerFrame(json: frameJSON(payload: eventPayloadBase64))
        #expect(frame.messageId == "CAAQAw==")
        #expect(frame.redeliveryCount == 0)
        #expect(frame.key == "opportunity-123")
        #expect(frame.properties["eventType"] == "T.v1")
    }

    /// The consume side delivers payload base64-encoded even though the REST
    /// produce side takes a raw string. This is the asymmetry that would
    /// otherwise fail silently end-to-end.
    @Test func base64DecodesPayloadIntoEvent() throws {
        let frame = try ConsumerFrame(json: frameJSON(payload: eventPayloadBase64))
        let event = try frame.decodedEvent()
        #expect(event.eventId == "e-1")
        #expect(event.recipientIds == ["u-1"])
        #expect(event.payload["opportunityId"] == "o-1")
    }

    @Test func rejectsNonBase64Payload() throws {
        let frame = try ConsumerFrame(json: frameJSON(payload: "not base64 !!!"))
        #expect(throws: ReceiveError.payloadNotBase64) { try frame.decodedEvent() }
    }

    @Test func rejectsBase64ThatIsNotAPublishedLanguageEvent() throws {
        let junk = Data(#"{"nope":true}"#.utf8).base64EncodedString()
        let frame = try ConsumerFrame(json: frameJSON(payload: junk))
        #expect(throws: (any Error).self) { try frame.decodedEvent() }
    }

    @Test func rejectsMalformedFrame() {
        #expect(throws: (any Error).self) { try ConsumerFrame(json: Data("not json".utf8)) }
    }

    /// Older brokers may omit redeliveryCount; absence means first delivery.
    @Test func defaultsRedeliveryCountWhenAbsent() throws {
        let json = Data(#"{"messageId":"m-1","payload":"e30="}"#.utf8)
        let frame = try ConsumerFrame(json: json)
        #expect(frame.redeliveryCount == 0)
        #expect(frame.properties.isEmpty)
    }

    @Test func recordReportsRedelivery() throws {
        let frame = try ConsumerFrame(json: frameJSON(payload: eventPayloadBase64, redeliveryCount: "3"))
        let record = ReceivedRecord(frame: frame, event: try frame.decodedEvent())
        #expect(record.redeliveryCount == 3)
        #expect(record.isRedelivery)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ConsumerFrameTests`
Expected: FAIL — `no such module 'ContextReceiver'`.

- [ ] **Step 3: Implement the frame, record, and error types**

`Sources/ContextReceiver/ConsumerFrame.swift`:

```swift
import Foundation
import PublishedLanguage

/// A single message frame delivered by Pulsar's WebSocket consumer endpoint.
public struct ConsumerFrame: Sendable, Codable {
    public let messageId: String
    public let payload: String
    public let publishTime: String?
    public let redeliveryCount: Int
    public let properties: [String: String]
    public let key: String?

    private enum CodingKeys: String, CodingKey {
        case messageId, payload, publishTime, redeliveryCount, properties, key
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageId = try container.decode(String.self, forKey: .messageId)
        payload = try container.decode(String.self, forKey: .payload)
        publishTime = try container.decodeIfPresent(String.self, forKey: .publishTime)
        // Absent means first delivery.
        redeliveryCount = try container.decodeIfPresent(Int.self, forKey: .redeliveryCount) ?? 0
        properties = try container.decodeIfPresent([String: String].self, forKey: .properties) ?? [:]
        key = try container.decodeIfPresent(String.self, forKey: .key)
    }

    public init(json: Data) throws {
        do {
            self = try JSONDecoder().decode(ConsumerFrame.self, from: json)
        } catch {
            throw ReceiveError.malformedFrame(String(decoding: json.prefix(256), as: UTF8.self))
        }
    }

    /// Base64-decodes `payload` and decodes the Published Language event from it.
    public func decodedEvent() throws -> PublishedLanguageEvent {
        guard let bytes = Data(base64Encoded: payload) else {
            throw ReceiveError.payloadNotBase64
        }
        do {
            return try PublishedLanguageEvent.wireDecoder.decode(
                PublishedLanguageEvent.self, from: bytes
            )
        } catch {
            throw ReceiveError.payloadNotDecodable(String(describing: error))
        }
    }
}

public enum ReceiveError: Error, Equatable, Sendable {
    /// A WebSocket text frame that is not a Pulsar message frame at all.
    case malformedFrame(String)
    case payloadNotBase64
    case payloadNotDecodable(String)
    /// The admin backlog probe could not read topic stats (Task 6).
    case adminProbeFailed(String)
    /// A settle or permit was attempted with no live socket (Task 7).
    case transportUnavailable(String)
}
```

`Sources/ContextReceiver/ReceivedRecord.swift`:

```swift
import PublishedLanguage

/// A decoded Published Language event plus the broker delivery metadata the
/// host needs to reason about retries.
public struct ReceivedRecord: Sendable {
    public let event: PublishedLanguageEvent
    public let messageId: String
    public let redeliveryCount: Int
    public let key: String?
    public let properties: [String: String]

    /// True when the broker has delivered this message before. Hosts rely on
    /// deterministic aggregate ids for idempotency; this only informs logging
    /// and escalation decisions.
    public var isRedelivery: Bool { redeliveryCount > 0 }

    public init(frame: ConsumerFrame, event: PublishedLanguageEvent) {
        self.event = event
        self.messageId = frame.messageId
        self.redeliveryCount = frame.redeliveryCount
        self.key = frame.key
        self.properties = frame.properties
    }
}
```

In `Package.swift`:

```swift
.library(name: "ContextReceiver", targets: ["ContextReceiver"]),
```

```swift
.target(
    name: "ContextReceiver",
    dependencies: [
        "PublishedLanguage",
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "Logging", package: "swift-log"),
    ]
),
.testTarget(name: "ContextReceiverTests", dependencies: ["ContextReceiver"]),
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ConsumerFrameTests` → PASS (7 tests). Must pass on macOS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ContextReceiver Tests/ContextReceiverTests Package.swift
git commit -m "feat: add ContextReceiver frame decoding"
```

---

### Task 4: Transport abstraction and the consume port

**Files:**
- Create: `Sources/ContextReceiver/PulsarMessageSource.swift`
- Create: `Sources/ContextReceiver/ReceiveDisposition.swift`
- Create: `Sources/ContextReceiver/PublishedLanguageHandler.swift`
- Test: `Tests/ContextReceiverTests/FakeMessageSource.swift` (test helper, plus its own tests)

**Interfaces:**
- Consumes: `ConsumerFrame` (Task 3).
- Produces:
  - `protocol PulsarMessageSource: Sendable` — `func frames() -> AsyncThrowingStream<ConsumerFrame, any Error>`; `func settle(messageId: String, as: ReceiveDisposition) async throws`; `func grantPermits(_ count: Int) async throws`.
  - `enum ReceiveDisposition: Equatable, Sendable` — `.ack`, `.nack`, `.dropToDeadLetter`; `init(for error: any Error)`.
  - `struct Settlement: Equatable, Sendable` — `messageId: String`, `disposition: ReceiveDisposition`. A named type, **not** a `(String, ReceiveDisposition)` tuple: Swift tuples do not conform to `Equatable`, so an array of them cannot be compared with `==` and the tests below would not compile.
  - `protocol PublishedLanguageHandler: Sendable` — `func handle(_ record: ReceivedRecord) async throws`.
  - `protocol TransientReceiveError: Error` — marker a host error can adopt to force `.nack`.
  - `actor FakeMessageSource: PulsarMessageSource` (test target) — `init(frames: [ConsumerFrame], failure: (any Error & Sendable)? = nil)`, `var settlements: [Settlement]`, `var grantedPermits: Int`.

**Why `.dropToDeadLetter` exists:** mirroring hardening ruling #2 (`.park` over silent drop), a decode failure must not be retried forever — the payload will never become valid. But it must also not vanish. `.dropToDeadLetter` NACKs with a marker so `maxRedeliverCount` routes it to the DLQ promptly, where Task 6's monitor will see it.

- [ ] **Step 1: Write the failing test for the fake and disposition mapping**

```swift
import Testing
@testable import ContextReceiver

@Suite("Receive disposition")
struct ReceiveDispositionTests {
    private struct Transient: Error, TransientReceiveError {}
    private struct Permanent: Error {}

    @Test func transientErrorsNack() {
        #expect(ReceiveDisposition(for: Transient()) == .nack)
    }

    /// A payload that cannot be decoded will never decode; retrying is pointless.
    @Test func decodeFailuresGoToDeadLetter() {
        #expect(ReceiveDisposition(for: ReceiveError.payloadNotBase64) == .dropToDeadLetter)
        #expect(ReceiveDisposition(for: ReceiveError.payloadNotDecodable("x")) == .dropToDeadLetter)
    }

    /// Unknown errors are treated as retryable: a transient outage misclassified
    /// as permanent loses a notification, which is worse than a redelivery.
    @Test func unknownErrorsDefaultToNack() {
        #expect(ReceiveDisposition(for: Permanent()) == .nack)
    }
}

@Suite("Fake message source")
struct FakeMessageSourceTests {
    @Test func yieldsFramesThenFinishes() async throws {
        let frame = try ConsumerFrame(json: Data(#"{"messageId":"m-1","payload":"e30="}"#.utf8))
        let source = FakeMessageSource(frames: [frame])
        var seen: [String] = []
        for try await f in source.frames() { seen.append(f.messageId) }
        #expect(seen == ["m-1"])
    }

    @Test func recordsSettlementsAndPermits() async throws {
        let source = FakeMessageSource(frames: [])
        try await source.settle(messageId: "m-1", as: .ack)
        try await source.grantPermits(5)
        #expect(await source.settlements == [Settlement(messageId: "m-1", disposition: .ack)])
        #expect(await source.grantedPermits == 5)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ReceiveDispositionTests`
Expected: FAIL — `cannot find 'ReceiveDisposition' in scope`.

- [ ] **Step 3: Implement the protocols and the fake**

`Sources/ContextReceiver/ReceiveDisposition.swift`:

```swift
/// One settled message. A named type rather than a tuple: Swift tuples do not
/// conform to `Equatable`, so `[(String, ReceiveDisposition)] == [...]` will not
/// compile and test assertions could not be written against it.
public struct Settlement: Equatable, Sendable {
    public let messageId: String
    public let disposition: ReceiveDisposition

    public init(messageId: String, disposition: ReceiveDisposition) {
        self.messageId = messageId
        self.disposition = disposition
    }
}

/// What to tell the broker about a message after the host has handled it.
public enum ReceiveDisposition: Equatable, Sendable {
    /// Handled successfully; remove from the subscription.
    case ack
    /// Retryable failure; redeliver after `negativeAckRedeliveryDelay`.
    case nack
    /// Unprocessable and always will be; push toward the dead letter topic
    /// rather than looping. Never a silent drop.
    case dropToDeadLetter
}

/// Host errors adopt this to declare themselves retryable.
public protocol TransientReceiveError: Error {}

extension ReceiveDisposition {
    public init(for error: any Error) {
        switch error {
        case is TransientReceiveError:
            self = .nack
        case ReceiveError.payloadNotBase64, ReceiveError.payloadNotDecodable:
            self = .dropToDeadLetter
        default:
            // Default to retry. Misreading a transient outage as permanent
            // loses a notification; a redelivery only costs a duplicate,
            // which host-side deterministic ids already absorb.
            self = .nack
        }
    }
}
```

`Sources/ContextReceiver/PulsarMessageSource.swift`:

```swift
/// The transport seam. `ContextReceiver` drives this and nothing else, so all
/// of its logic is testable without a broker or a socket.
public protocol PulsarMessageSource: Sendable {
    /// Frames as they arrive. Finishes on a clean close; throws on transport failure.
    func frames() -> AsyncThrowingStream<ConsumerFrame, any Error>
    func settle(messageId: String, as disposition: ReceiveDisposition) async throws
    /// Pull-mode flow control: asks the broker for `count` more messages.
    func grantPermits(_ count: Int) async throws
}
```

`Sources/ContextReceiver/PublishedLanguageHandler.swift`:

```swift
/// Implemented by the downstream context: translate a Published Language
/// event into local domain intent. Throwing decides the disposition, so
/// hosts should adopt `TransientReceiveError` on retryable failures.
public protocol PublishedLanguageHandler: Sendable {
    func handle(_ record: ReceivedRecord) async throws
}
```

`Tests/ContextReceiverTests/FakeMessageSource.swift`:

```swift
import Foundation
@testable import ContextReceiver

actor FakeMessageSource: PulsarMessageSource {
    // `nonisolated let` so `frames()` can read them without hopping onto the
    // actor — an `await` on an immutable Sendable property is a warning.
    private nonisolated let queued: [ConsumerFrame]
    /// When set, `frames()` throws this after yielding everything queued.
    /// `& Sendable` is required: a bare `any Error` is not Sendable and cannot
    /// be held in a `nonisolated let`.
    private nonisolated let failure: (any Error & Sendable)?
    private(set) var settlements: [Settlement] = []
    private(set) var grantedPermits = 0

    init(frames: [ConsumerFrame], failure: (any Error & Sendable)? = nil) {
        self.queued = frames
        self.failure = failure
    }

    nonisolated func frames() -> AsyncThrowingStream<ConsumerFrame, any Error> {
        AsyncThrowingStream { continuation in
            for frame in queued { continuation.yield(frame) }
            if let failure {
                continuation.finish(throwing: failure)
            } else {
                continuation.finish()
            }
        }
    }

    func settle(messageId: String, as disposition: ReceiveDisposition) async throws {
        settlements.append(Settlement(messageId: messageId, disposition: disposition))
    }

    func grantPermits(_ count: Int) async throws {
        grantedPermits += count
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ReceiveDispositionTests` → PASS (3 tests).
Run: `swift test --filter FakeMessageSourceTests` → PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ContextReceiver Tests/ContextReceiverTests
git commit -m "feat: add transport seam, disposition rules, and consume port"
```

---

### Task 5: The runner

**Files:**
- Create: `Sources/ContextReceiver/ContextReceiver.swift`
- Test: `Tests/ContextReceiverTests/ContextReceiverTests.swift`

**Interfaces:**
- Consumes: `PulsarMessageSource`, `PublishedLanguageHandler`, `ReceiveDisposition`, `ReceivedRecord`, `ConsumerFrame`.
- Produces: `struct ContextReceiver: Sendable` with `struct FlowSettings: Sendable { var initialPermits: Int = 100; var permitRefillThreshold: Int = 50 }`, `init(source:handler:flow:logger:)`, `func run() async throws`.

**Behaviour to encode:** grant `initialPermits` before consuming; for each frame decode → handle → settle; refill permits once `permitRefillThreshold` messages have been settled since the last grant (a sliding window, not one permit per message — batching avoids a broker round-trip per message); a decode failure settles `.dropToDeadLetter` without invoking the handler; a handler throw maps through `ReceiveDisposition(for:)`; a settle failure is logged and does not abort the loop, because the message will be redelivered anyway.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Logging
import Testing
import PublishedLanguage
@testable import ContextReceiver

@Suite("ContextReceiver runner")
struct ContextReceiverTests {
    private struct Transient: Error, TransientReceiveError {}

    private actor RecordingHandler: PublishedLanguageHandler {
        private(set) var handled: [ReceivedRecord] = []
        private let thrown: (any Error)?
        init(throwing thrown: (any Error)? = nil) { self.thrown = thrown }
        func handle(_ record: ReceivedRecord) async throws {
            handled.append(record)
            if let thrown { throw thrown }
        }
        var handledIds: [String] { handled.map(\.event.eventId) }
    }

    private func frame(id: String, eventId: String, redeliveryCount: Int = 0) throws -> ConsumerFrame {
        let event = """
        {"eventId":"\(eventId)","eventType":"T.v1","occurredAt":"2026-08-14T01:02:03Z",\
        "recipientIds":["u-1"],"payload":{}}
        """
        let b64 = Data(event.utf8).base64EncodedString()
        return try ConsumerFrame(json: Data("""
        {"messageId":"\(id)","payload":"\(b64)","redeliveryCount":\(redeliveryCount)}
        """.utf8))
    }

    private func badFrame(id: String) throws -> ConsumerFrame {
        try ConsumerFrame(json: Data(#"{"messageId":"\#(id)","payload":"!!!not base64!!!"}"#.utf8))
    }

    private var logger: Logger { Logger(label: "test") }

    @Test func acksAfterSuccessfulHandling() async throws {
        let source = FakeMessageSource(frames: [try frame(id: "m-1", eventId: "e-1")])
        let handler = RecordingHandler()
        try await ContextReceiver(source: source, handler: handler, logger: logger).run()
        #expect(await handler.handledIds == ["e-1"])
        #expect(await source.settlements.map(\.disposition) == [.ack])
    }

    @Test func nacksWhenHandlerThrowsTransiently() async throws {
        let source = FakeMessageSource(frames: [try frame(id: "m-1", eventId: "e-1")])
        let handler = RecordingHandler(throwing: Transient())
        try await ContextReceiver(source: source, handler: handler, logger: logger).run()
        #expect(await source.settlements == [Settlement(messageId: "m-1", disposition: .nack)])
    }

    /// An undecodable payload must never reach the handler, and must not loop.
    @Test func routesUndecodableFramesToDeadLetterWithoutHandling() async throws {
        let source = FakeMessageSource(frames: [try badFrame(id: "m-bad")])
        let handler = RecordingHandler()
        try await ContextReceiver(source: source, handler: handler, logger: logger).run()
        #expect(await handler.handled.isEmpty)
        #expect(await source.settlements == [Settlement(messageId: "m-bad", disposition: .dropToDeadLetter)])
    }

    @Test func grantsInitialPermitsBeforeConsuming() async throws {
        let source = FakeMessageSource(frames: [])
        var flow = ContextReceiver.FlowSettings()
        flow.initialPermits = 42
        try await ContextReceiver(
            source: source, handler: RecordingHandler(), flow: flow, logger: logger
        ).run()
        #expect(await source.grantedPermits == 42)
    }

    @Test func refillsPermitsAfterThresholdSettlements() async throws {
        let frames = try (1...6).map { try frame(id: "m-\($0)", eventId: "e-\($0)") }
        let source = FakeMessageSource(frames: frames)
        var flow = ContextReceiver.FlowSettings()
        flow.initialPermits = 10
        flow.permitRefillThreshold = 3
        try await ContextReceiver(
            source: source, handler: RecordingHandler(), flow: flow, logger: logger
        ).run()
        // 10 initial + two refills of 3 after the 3rd and 6th settlement.
        #expect(await source.grantedPermits == 16)
    }

    @Test func surfacesRedeliveryCountToHandler() async throws {
        let source = FakeMessageSource(frames: [try frame(id: "m-1", eventId: "e-1", redeliveryCount: 4)])
        let handler = RecordingHandler()
        try await ContextReceiver(source: source, handler: handler, logger: logger).run()
        #expect(await handler.handled.first?.redeliveryCount == 4)
        #expect(await handler.handled.first?.isRedelivery == true)
    }

    @Test func propagatesTransportFailure() async throws {
        struct Dropped: Error {}
        let source = FakeMessageSource(frames: [], failure: Dropped())
        await #expect(throws: Dropped.self) {
            try await ContextReceiver(
                source: source, handler: RecordingHandler(), logger: logger
            ).run()
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ContextReceiverTests`
Expected: FAIL — `cannot find 'ContextReceiver' in scope`.

- [ ] **Step 3: Implement the runner**

```swift
import Logging

/// Drives a `PulsarMessageSource` into a `PublishedLanguageHandler`, settling
/// each message with the broker. Mirrors `ContextForwarder` on the consume side.
public struct ContextReceiver: Sendable {
    public struct FlowSettings: Sendable {
        /// Permits granted before consuming starts. Bounds in-flight messages.
        public var initialPermits: Int = 100
        /// Settlements to accumulate before asking for more. Batching avoids a
        /// broker round-trip per message.
        public var permitRefillThreshold: Int = 50
        public init() {}
    }

    private let source: any PulsarMessageSource
    private let handler: any PublishedLanguageHandler
    private let flow: FlowSettings
    private let logger: Logger

    public init(
        source: any PulsarMessageSource,
        handler: any PublishedLanguageHandler,
        flow: FlowSettings = .init(),
        logger: Logger
    ) {
        self.source = source
        self.handler = handler
        self.flow = flow
        self.logger = logger
    }

    public func run() async throws {
        try await source.grantPermits(flow.initialPermits)
        var settledSinceRefill = 0

        for try await frame in source.frames() {
            let outcome = await disposition(for: frame)
            do {
                try await source.settle(messageId: frame.messageId, as: outcome)
            } catch {
                // The broker will redeliver on ack-timeout, so a failed settle
                // is recoverable. Aborting the loop would strand the rest.
                logger.error("failed to settle message", metadata: [
                    "messageId": "\(frame.messageId)",
                    "disposition": "\(outcome)",
                    "error": "\(error)",
                ])
            }

            settledSinceRefill += 1
            if settledSinceRefill >= flow.permitRefillThreshold {
                try await source.grantPermits(settledSinceRefill)
                settledSinceRefill = 0
            }
        }
    }

    /// Decides the disposition for one frame. Never throws: every outcome is a
    /// disposition, so one bad message cannot end the subscription.
    private func disposition(for frame: ConsumerFrame) async -> ReceiveDisposition {
        let event: PublishedLanguageEvent
        do {
            event = try frame.decodedEvent()
        } catch {
            logger.error("undecodable payload, routing to dead letter", metadata: [
                "messageId": "\(frame.messageId)", "error": "\(error)",
            ])
            return ReceiveDisposition(for: error)
        }

        let record = ReceivedRecord(frame: frame, event: event)
        do {
            try await handler.handle(record)
            return .ack
        } catch {
            let disposition = ReceiveDisposition(for: error)
            logger.warning("handler failed", metadata: [
                "messageId": "\(frame.messageId)",
                "eventId": "\(event.eventId)",
                "redeliveryCount": "\(record.redeliveryCount)",
                "disposition": "\(disposition)",
                "error": "\(error)",
            ])
            return disposition
        }
    }
}
```

Add `import PublishedLanguage` at the top.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ContextReceiverTests` → PASS (7 tests). Must pass on macOS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ContextReceiver/ContextReceiver.swift Tests/ContextReceiverTests/ContextReceiverTests.swift
git commit -m "feat: add ContextReceiver runner with permit-based flow control"
```

---

### Task 6: Dead letter backlog monitor

**Files:**
- Create: `Sources/ContextReceiver/DeadLetterMonitor.swift`
- Test: `Tests/ContextReceiverTests/DeadLetterMonitorTests.swift`

**Interfaces:**
- Produces:
  - `protocol DeadLetterBacklogProbe: Sendable` — `func backlogCount(topic: String) async throws -> Int`.
  - `struct PulsarAdminBacklogProbe: DeadLetterBacklogProbe, Sendable` — `init(adminBaseURL: String, httpClient: HTTPClient, authorizationHeader: @Sendable () async throws -> String?)`.
  - `struct DeadLetterMonitor: Sendable` — `init(probe:topic:interval:threshold:maxChecks:logger:onAlert:)` where `maxChecks: Int?` (nil runs until cancelled; tests pass a finite count) and `onAlert: @Sendable (Int) async -> Void`; `func run() async throws`.

**Why:** hardening ruling #1 put parked-message alerting inside the framework rather than leaving each host to remember it. Pulsar's DLQ is the parked queue here, so the same obligation applies: a message that reaches the DLQ is a notification nobody received, and it is silent by default.

- [ ] **Step 1: Write the failing tests**

```swift
import Logging
import Testing
@testable import ContextReceiver

@Suite("Dead letter monitor")
struct DeadLetterMonitorTests {
    private actor StubProbe: DeadLetterBacklogProbe {
        private var counts: [Int]
        private(set) var calls = 0
        init(counts: [Int]) { self.counts = counts }
        func backlogCount(topic: String) async throws -> Int {
            defer { calls += 1 }
            return counts.indices.contains(calls) ? counts[calls] : counts.last ?? 0
        }
    }

    private actor AlertSink {
        private(set) var alerts: [Int] = []
        func record(_ count: Int) { alerts.append(count) }
    }

    private var logger: Logger { Logger(label: "test") }

    @Test func alertsWhenBacklogCrossesThreshold() async throws {
        let probe = StubProbe(counts: [0, 7])
        let sink = AlertSink()
        let monitor = DeadLetterMonitor(
            probe: probe, topic: "t-DLQ", interval: .milliseconds(1),
            threshold: 5, maxChecks: 2, logger: logger,
            onAlert: { await sink.record($0) }
        )
        try await monitor.run()
        #expect(await sink.alerts == [7])
    }

    @Test func staysSilentBelowThreshold() async throws {
        let probe = StubProbe(counts: [0, 1])
        let sink = AlertSink()
        let monitor = DeadLetterMonitor(
            probe: probe, topic: "t-DLQ", interval: .milliseconds(1),
            threshold: 5, maxChecks: 2, logger: logger,
            onAlert: { await sink.record($0) }
        )
        try await monitor.run()
        #expect(await sink.alerts.isEmpty)
    }

    /// A probe failure must not kill the monitor — the DLQ is still filling.
    @Test func survivesProbeFailure() async throws {
        actor FailingProbe: DeadLetterBacklogProbe {
            private(set) var calls = 0
            func backlogCount(topic: String) async throws -> Int {
                calls += 1
                throw ReceiveError.adminProbeFailed("HTTP 503")
            }
        }
        let probe = FailingProbe()
        let monitor = DeadLetterMonitor(
            probe: probe, topic: "t-DLQ", interval: .milliseconds(1),
            threshold: 1, maxChecks: 3, logger: logger, onAlert: { _ in }
        )
        try await monitor.run()
        #expect(await probe.calls == 3)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter DeadLetterMonitorTests`
Expected: FAIL — `cannot find 'DeadLetterMonitor' in scope`.

- [ ] **Step 3: Implement the monitor and the admin probe**

```swift
import AsyncHTTPClient
import Foundation
import Logging
import NIOCore

/// Reads the message backlog of a topic. Abstracted so the monitor is testable
/// without a broker.
public protocol DeadLetterBacklogProbe: Sendable {
    func backlogCount(topic: String) async throws -> Int
}

/// Reads `msgBacklog` from Pulsar's admin stats endpoint.
public struct PulsarAdminBacklogProbe: DeadLetterBacklogProbe {
    private let adminBaseURL: String
    private let httpClient: HTTPClient
    private let authorizationHeader: @Sendable () async throws -> String?

    public init(
        adminBaseURL: String,
        httpClient: HTTPClient,
        authorizationHeader: @escaping @Sendable () async throws -> String? = { nil }
    ) {
        self.adminBaseURL = adminBaseURL
        self.httpClient = httpClient
        self.authorizationHeader = authorizationHeader
    }

    public func backlogCount(topic: String) async throws -> Int {
        var request = HTTPClientRequest(
            url: "\(adminBaseURL)/admin/v2/persistent/\(topic)/stats"
        )
        request.method = .GET
        if let authorization = try await authorizationHeader() {
            request.headers.add(name: "Authorization", value: authorization)
        }
        let response = try await httpClient.execute(request, timeout: .seconds(10))
        let body = try await response.body.collect(upTo: 1 << 20)
        guard response.status == .ok else {
            throw ReceiveError.adminProbeFailed("HTTP \(response.status.code): \(String(buffer: body))")
        }
        struct Stats: Decodable { let msgBacklog: Int? }
        // ByteBuffer(bytes:)/readableBytesView are NIOCore spellings; the
        // Foundation-bridging ones live in NIOFoundationCompat and are not
        // portable to Linux.
        let stats = try JSONDecoder().decode(Stats.self, from: Data(body.readableBytesView))
        return stats.msgBacklog ?? 0
    }
}

/// Periodically checks a dead letter topic's backlog and alerts when it grows.
/// A message in the DLQ is a notification nobody received; by default nothing
/// surfaces that, so the framework does it rather than each host.
public struct DeadLetterMonitor: Sendable {
    private let probe: any DeadLetterBacklogProbe
    private let topic: String
    private let interval: Duration
    private let threshold: Int
    /// Bounded run length. `nil` runs until cancelled; tests pass a finite count.
    private let maxChecks: Int?
    private let logger: Logger
    private let onAlert: @Sendable (Int) async -> Void

    public init(
        probe: any DeadLetterBacklogProbe,
        topic: String,
        interval: Duration = .seconds(60),
        threshold: Int = 1,
        maxChecks: Int? = nil,
        logger: Logger,
        onAlert: @escaping @Sendable (Int) async -> Void
    ) {
        self.probe = probe
        self.topic = topic
        self.interval = interval
        self.threshold = threshold
        self.maxChecks = maxChecks
        self.logger = logger
        self.onAlert = onAlert
    }

    public func run() async throws {
        var checks = 0
        while maxChecks.map({ checks < $0 }) ?? true {
            checks += 1
            do {
                let count = try await probe.backlogCount(topic: topic)
                if count >= threshold {
                    logger.error("dead letter backlog above threshold", metadata: [
                        "topic": "\(topic)", "backlog": "\(count)", "threshold": "\(threshold)",
                    ])
                    await onAlert(count)
                }
            } catch {
                // Keep polling: the backlog is still growing whether or not we
                // can read it, and giving up would make the silence permanent.
                logger.warning("dead letter probe failed", metadata: [
                    "topic": "\(topic)", "error": "\(error)",
                ])
            }
            try await Task.sleep(for: interval)
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter DeadLetterMonitorTests` → PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ContextReceiver/DeadLetterMonitor.swift Tests/ContextReceiverTests/DeadLetterMonitorTests.swift
git commit -m "feat: alert on dead letter backlog growth"
```

---

### Task 7: The WebSocket transport (Linux-only target)

**Files:**
- Create: `Sources/ContextReceiverWebSocket/WebSocketMessageSource.swift`
- Create: `Sources/ContextReceiver/ConsumerEndpoint.swift` — the URL builder lives in the **portable** target so its tests run on macOS
- Modify: `Package.swift` — add `swift-websocket` dependency and the `ContextReceiverWebSocket` target
- Test: `Tests/ContextReceiverTests/ConsumerEndpointTests.swift`

**Interfaces:**
- Consumes: `PulsarMessageSource`, `ConsumerFrame`, `ReceiveDisposition`.
- Produces:
  - `struct ConsumerEndpoint: Sendable` (in `ContextReceiver`) — `init(baseURL:tenant:namespace:topic:subscription:settings:)`, `var url: String`, `struct Settings: Sendable` with `subscriptionType: String = "Key_Shared"`, `consumerName: String?`, `maxRedeliverCount: Int?`, `deadLetterTopic: String?`, `negativeAckRedeliveryDelayMillis: Int?`, `receiverQueueSize: Int?`.
  - `actor WebSocketMessageSource: PulsarMessageSource` (in `ContextReceiverWebSocket`) — `init(endpoint:authorizationHeader:logger:)`, `func run() async throws`.

> **Corrected during execution — do not restore the earlier design.** An earlier draft of this
> task gave the transport an internal reconnect ladder (`reconnectBackoff:`) that caught socket
> failures and retried transparently. That is a **silent-stall bug**, not a resilience feature.
> A reconnect creates a new broker-side consumer session whose permit budget is zero (that is
> what `pullMode=true` means), but the runner grants `initialPermits` exactly once before its
> loop and refills only after `permitRefillThreshold` settlements. A transparent reconnect
> therefore leaves the runner waiting on a session that will never push anything: no frames, so
> the settle counter never advances, so no refill ever happens. After any broker restart, deploy,
> or idle drop the receiver becomes a silent zombie whose only trace is one warning line.
>
> The shipped contract instead matches `PulsarMessageSource`'s documented one: **one instance ==
> one socket session.** `run()` connects once; on transport failure it calls
> `continuation.finish(throwing:)` and rethrows; on clean close it finishes cleanly and returns.
> Supervision — backoff, discarding the source, recreating it, and re-granting initial permits —
> belongs to the host, the only layer that can restart the runner alongside the socket.

**Note on `pullMode`:** `ConsumerEndpoint` always sets `pullMode=true`; the runner's permit accounting depends on it, so it is not configurable.

- [ ] **Step 1: Write the failing URL builder tests**

```swift
import Testing
@testable import ContextReceiver

@Suite("Consumer endpoint URL")
struct ConsumerEndpointTests {
    private func endpoint(_ settings: ConsumerEndpoint.Settings = .init()) -> ConsumerEndpoint {
        ConsumerEndpoint(
            baseURL: "ws://pulsar.internal:8080",
            tenant: "public", namespace: "default",
            topic: "opportunity-published-language",
            subscription: "notification-center",
            settings: settings
        )
    }

    @Test func buildsConsumerPath() {
        #expect(endpoint().url.hasPrefix(
            "ws://pulsar.internal:8080/ws/v2/consumer/persistent/public/default/opportunity-published-language/notification-center?"
        ))
    }

    /// Pull mode is mandatory: the runner's permit accounting depends on it.
    @Test func alwaysEnablesPullMode() {
        #expect(endpoint().url.contains("pullMode=true"))
    }

    @Test func defaultsToKeySharedForPerKeyOrdering() {
        #expect(endpoint().url.contains("subscriptionType=Key_Shared"))
    }

    @Test func includesOptionalSettingsOnlyWhenSet() {
        var settings = ConsumerEndpoint.Settings()
        settings.maxRedeliverCount = 5
        settings.deadLetterTopic = "persistent://public/default/notification-dlq"
        let url = endpoint(settings).url
        #expect(url.contains("maxRedeliverCount=5"))
        #expect(url.contains("deadLetterTopic=persistent%3A%2F%2Fpublic%2Fdefault%2Fnotification-dlq"))
        #expect(!url.contains("consumerName"))
        #expect(!url.contains("negativeAckRedeliveryDelay"))
    }

    /// Auth must never ride in the query string — it lands in broker access logs.
    @Test func neverPutsTokenInQueryString() {
        #expect(!endpoint().url.contains("token="))
    }

    @Test func trimsTrailingSlashOnBaseURL() {
        let e = ConsumerEndpoint(
            baseURL: "ws://pulsar.internal:8080/",
            tenant: "public", namespace: "default", topic: "t", subscription: "s"
        )
        #expect(e.url.contains("://pulsar.internal:8080/ws/v2/"))
        #expect(!e.url.contains("8080//ws"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ConsumerEndpointTests`
Expected: FAIL — `cannot find 'ConsumerEndpoint' in scope`.

- [ ] **Step 3: Implement the endpoint builder in the portable target**

`Sources/ContextReceiver/ConsumerEndpoint.swift`:

```swift
import Foundation

/// Builds the Pulsar WebSocket consumer URL. Lives in the portable target so
/// it can be unit-tested on any platform.
public struct ConsumerEndpoint: Sendable {
    public struct Settings: Sendable {
        /// Key_Shared gives per-key ordering plus multi-consumer scale-out.
        public var subscriptionType: String = "Key_Shared"
        public var consumerName: String?
        public var maxRedeliverCount: Int?
        public var deadLetterTopic: String?
        public var negativeAckRedeliveryDelayMillis: Int?
        public var receiverQueueSize: Int?
        public init() {}
    }

    private let baseURL: String
    private let tenant: String
    private let namespace: String
    private let topic: String
    private let subscription: String
    private let settings: Settings

    public init(
        baseURL: String, tenant: String, namespace: String,
        topic: String, subscription: String, settings: Settings = .init()
    ) {
        self.baseURL = baseURL
        self.tenant = tenant
        self.namespace = namespace
        self.topic = topic
        self.subscription = subscription
        self.settings = settings
    }

    public var url: String {
        let root = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let path = "\(root)/ws/v2/consumer/persistent/\(tenant)/\(namespace)/\(topic)/\(subscription)"

        var items = [
            URLQueryItem(name: "subscriptionType", value: settings.subscriptionType),
            // Not configurable: the runner grants permits explicitly.
            URLQueryItem(name: "pullMode", value: "true"),
        ]
        if let name = settings.consumerName {
            items.append(URLQueryItem(name: "consumerName", value: name))
        }
        if let count = settings.maxRedeliverCount {
            items.append(URLQueryItem(name: "maxRedeliverCount", value: "\(count)"))
        }
        if let dlq = settings.deadLetterTopic {
            items.append(URLQueryItem(name: "deadLetterTopic", value: dlq))
        }
        if let delay = settings.negativeAckRedeliveryDelayMillis {
            items.append(URLQueryItem(name: "negativeAckRedeliveryDelay", value: "\(delay)"))
        }
        if let size = settings.receiverQueueSize {
            items.append(URLQueryItem(name: "receiverQueueSize", value: "\(size)"))
        }

        var components = URLComponents(string: path)!
        components.queryItems = items
        // URLComponents leaves ":" and "/" unescaped in query values, but the
        // deadLetterTopic value is a persistent:// URI and must be escaped.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: ":", with: "%3A")
            .replacingOccurrences(of: "/", with: "%2F")
        return components.string!
    }
}
```

- [ ] **Step 4: Run the URL tests to verify they pass**

Run: `swift test --filter ConsumerEndpointTests` → PASS (6 tests) **on macOS**.

- [ ] **Step 5: Add the Linux-only transport target**

In `Package.swift` add the dependency and target:

```swift
// Pinned to upstream. Does not build on the macOS 26 SDK (missing @available
// on ByteBuffer.init(_uint8Span:)); Linux is verified clean on Swift 6.2.4.
// This is why the WebSocket transport is its own target — every other target
// and all unit tests stay buildable on macOS.
.package(url: "https://github.com/hummingbird-project/swift-websocket.git", from: "1.6.1"),
```

```swift
.library(name: "ContextReceiverWebSocket", targets: ["ContextReceiverWebSocket"]),
```

```swift
.target(
    name: "ContextReceiverWebSocket",
    dependencies: [
        "ContextReceiver",
        // Platform-conditional so macOS never compiles swift-websocket at all.
        // Without the condition, `swift build` on macOS fails for the whole
        // package — including for OpportunityContext developers who never
        // touch the receiver.
        .product(name: "WSClient", package: "swift-websocket", condition: .when(platforms: [.linux])),
    ]
),
```

The target's source must therefore also be platform-guarded, or macOS would compile
`import WSClient` against a dependency that is not there. Wrap the **entire body** of
`Sources/ContextReceiverWebSocket/WebSocketMessageSource.swift`:

```swift
#if os(Linux)
// ...the whole implementation below...
#endif
```

On macOS the module compiles empty. This keeps `swift build` and `swift test` working
on macOS while the real transport exists only where it can build.

- [ ] **Step 6: Implement the transport**

`Sources/ContextReceiverWebSocket/WebSocketMessageSource.swift`:

```swift
import ContextReceiver
import Foundation
import HTTPTypes
import Logging
import NIOCore
import WSClient

/// Pulsar WebSocket consumer transport. Owns the socket, translates frames,
/// and reconnects with backoff. Unacked messages are redelivered by the broker
/// after a reconnect, which is why at-least-once plus host-side deterministic
/// ids is the required contract.
public actor WebSocketMessageSource: PulsarMessageSource {
    private let endpoint: ConsumerEndpoint
    private let authorizationHeader: @Sendable () async throws -> String?
    private let logger: Logger

    private var outbound: WebSocketOutboundWriter?

    // Built eagerly in init, NOT lazily inside frames(). A lazily-stored
    // continuation is nil until an unstructured Task lands, and the runner grants
    // permits before it starts iterating — so the broker can legitimately push
    // into that window and every frame yielded there is discarded silently,
    // permanently shrinking the permit window. Both are `nonisolated let` because
    // the continuation is Sendable and frames() is nonisolated.
    private nonisolated let stream: AsyncThrowingStream<ConsumerFrame, any Error>
    private nonisolated let continuation: AsyncThrowingStream<ConsumerFrame, any Error>.Continuation

    public init(
        endpoint: ConsumerEndpoint,
        authorizationHeader: @escaping @Sendable () async throws -> String? = { nil },
        logger: Logger
    ) {
        self.endpoint = endpoint
        self.authorizationHeader = authorizationHeader
        self.logger = logger
        (self.stream, self.continuation) = AsyncThrowingStream.makeStream()
    }

    public nonisolated func frames() -> AsyncThrowingStream<ConsumerFrame, any Error> { stream }

    private func setOutbound(_ writer: WebSocketOutboundWriter?) {
        self.outbound = writer
    }

    private nonisolated func yield(_ frame: ConsumerFrame) {
        continuation.yield(frame)
    }

    /// Connects and pumps frames for exactly one socket session.
    ///
    /// Throws on transport failure after finishing the stream with that error;
    /// finishes cleanly and returns when the broker closes the socket. Does NOT
    /// reconnect — see the correction note in this task's Interfaces section for
    /// why an internal reconnect silently stalls the runner. The host supervises.
    public func run() async throws {
        defer { continuation.finish() }   // reached on every path, cancellation included
        do {
            try await connectOnce()
        } catch {
            // finish(throwing:) BEFORE rethrowing, so the consumer of frames()
            // sees the cause rather than a bare completion. The defer's later
            // bare finish() is a no-op: the first termination wins.
            continuation.finish(throwing: error)
            throw error
        }
    }

    private func connectOnce() async throws {
        // Isolated + synchronous, so it is ordered before any later connect.
        // The earlier `defer { Task { await self.setOutbound(nil) } }` was
        // unstructured and could null out a NEWER socket's writer, leaving every
        // settle/grantPermits throwing transportUnavailable for a healthy socket.
        defer { outbound = nil }

        var configuration = WebSocketClientConfiguration()
        if let authorization = try await authorizationHeader() {
            // Header, not the `token` query parameter: query strings are logged
            // by the broker.
            configuration.additionalHeaders = [.authorization: authorization]
        }
        configuration.autoPing = .enabled(timePeriod: .seconds(30))

        _ = try await WebSocketClient.connect(
            url: endpoint.url,
            configuration: configuration,
            logger: logger
        ) { inbound, outbound, _ in
            await self.setOutbound(outbound)
            // No clear here — the isolated `defer` in connectOnce owns that.
            // Pulsar sends JSON text frames.
            for try await message in inbound.messages(maxSize: 1 << 20) {
                guard case .text(let json) = message else { continue }
                do {
                    self.yield(try ConsumerFrame(json: Data(json.utf8)))
                } catch {
                    // Could be a routine ack/permit receipt OR a broker rejection.
                    // Classify before discarding: a silently rejected permit command
                    // is another route to a permanently stalled consumer, and at
                    // `debug` nobody would ever see it. See logNonMessageFrame —
                    // `errorMsg` present, or `result` present and not "ok", logs at
                    // `error`. autoPing handles ping/pong at the protocol level, so
                    // ping frames never arrive here.
                    self.logNonMessageFrame(json)
                }
            }
        }
    }

    public func settle(messageId: String, as disposition: ReceiveDisposition) async throws {
        let json: String
        switch disposition {
        case .ack:
            json = #"{"messageId":"\#(messageId)"}"#
        case .nack, .dropToDeadLetter:
            // Both negatively acknowledge; maxRedeliverCount routes repeatedly
            // failing messages to the dead letter topic.
            json = #"{"type":"negativeAcknowledge","messageId":"\#(messageId)"}"#
        }
        try await send(json)
    }

    public func grantPermits(_ count: Int) async throws {
        try await send(#"{"type":"permit","permitMessages":\#(count)}"#)
    }

    private func send(_ json: String) async throws {
        guard let outbound else {
            throw ReceiveError.transportUnavailable("socket not connected")
        }
        try await outbound.writeTextMessage(json)
    }
}
```

- [ ] **Step 7: Verify the Linux build**

The real implementation only compiles on Linux. Run:

```bash
docker run --rm -v "$PWD":/src -w /src swift:6.2-noble \
  bash -c 'swift build --target ContextReceiverWebSocket 2>&1 | tail -20; exit ${PIPESTATUS[0]}'
echo "exit=$?"
```

Expected: `exit=0`. Capture the exit code explicitly — a `tail` in a pipeline otherwise masks the compiler's status, which has produced a false "verified" claim on this project before.

Then confirm macOS is still healthy for the **whole package**, not just one target — this is what the `#if os(Linux)` guard and the conditional dependency exist to guarantee:

```bash
swift build && swift test --filter ContextReceiverTests
```

Both must succeed. If `swift build` fails on macOS, the guard or the dependency condition is wrong — fix it rather than narrowing the command.

- [ ] **Step 8: Commit**

```bash
git add Sources/ContextReceiver/ConsumerEndpoint.swift Sources/ContextReceiverWebSocket \
        Tests/ContextReceiverTests/ConsumerEndpointTests.swift Package.swift
git commit -m "feat: add Pulsar WebSocket consumer transport"
```

---

### Task 8: Live end-to-end verification against a real broker

**Files:**
- Create: `Tests/ContextReceiverIntegrationTests/LivePulsarTests.swift`
- Create: `docker-compose.pulsar.yml`
- Modify: `Package.swift` — add the integration test target
- Modify: `.github/workflows/swift-build-testing.yml` — extend the `--filter` allowlist
- Modify: `README.md` — document the receiver and how to run the integration suite

**Interfaces:**
- Consumes: everything from Tasks 1–7.

**Why this task exists:** the forwarder has never been exercised against a real Pulsar. Every produce-side assertion so far checks the JSON we *intend* to send. The payload asymmetry (raw string out, base64 in) and the absent `valueSchema` field are exactly the kind of thing that only fails against a live broker. This task closes that loop.

- [ ] **Step 1: Add the broker compose file**

`docker-compose.pulsar.yml`:

```yaml
services:
  pulsar:
    image: apachepulsar/pulsar:4.0.3
    command: bin/pulsar standalone
    ports:
      - "6650:6650"   # binary protocol
      - "8080:8080"   # REST admin + WebSocket
    environment:
      PULSAR_MEM: "-Xms512m -Xmx512m"
    healthcheck:
      test: ["CMD", "bin/pulsar-admin", "brokers", "healthcheck"]
      interval: 10s
      timeout: 10s
      retries: 12
```

- [ ] **Step 2: Write the env-gated round-trip test**

```swift
import AsyncHTTPClient
import Foundation
import Logging
import Testing
import PublishedLanguage
import ContextReceiver
import ContextReceiverWebSocket
import ContextForwarder

/// Gated on PULSAR_HTTP_URL so the default `swift test` stays offline, matching
/// the project's existing integration-test convention.
@Suite("Live Pulsar round trip", .enabled(if: ProcessInfo.processInfo.environment["PULSAR_HTTP_URL"] != nil))
struct LivePulsarTests {
    private var httpURL: String { ProcessInfo.processInfo.environment["PULSAR_HTTP_URL"]! }
    private var wsURL: String {
        ProcessInfo.processInfo.environment["PULSAR_WS_URL"]
            ?? httpURL.replacingOccurrences(of: "http://", with: "ws://")
    }

    private actor Collector: PublishedLanguageHandler {
        private(set) var received: [ReceivedRecord] = []
        func handle(_ record: ReceivedRecord) async throws { received.append(record) }
        func waitForCount(_ count: Int, timeout: Duration) async throws -> Bool {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline {
                if received.count >= count { return true }
                try await Task.sleep(for: .milliseconds(100))
            }
            return false
        }
    }

    /// Proves the produce/consume payload asymmetry is handled: the forwarder
    /// sends a raw JSON string, the broker hands it back base64-encoded, and
    /// the event survives the trip intact.
    @Test func forwarderPublishesAndReceiverConsumes() async throws {
        let logger = Logger(label: "live")
        let topic = "ctxrecv-itest-\(UUID().uuidString.prefix(8))"
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { try? httpClient.syncShutdown() }

        let endpoint = ConsumerEndpoint(
            baseURL: wsURL, tenant: "public", namespace: "default",
            topic: topic, subscription: "itest"
        )
        let source = WebSocketMessageSource(endpoint: endpoint, logger: logger)
        let collector = Collector()
        let receiver = ContextReceiver(source: source, handler: collector, logger: logger)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await source.run() }
            group.addTask { try await receiver.run() }

            // Let the subscription attach before producing, otherwise the
            // message lands before the cursor exists.
            try await Task.sleep(for: .seconds(3))

            let event = PublishedLanguageEvent(
                eventId: "e-live-1",
                eventType: "ItestEvent.v1",
                occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
                recipientIds: ["u-1"],
                payload: ["opportunityId": "o-1"],
                partitionKey: "opportunity-123"
            )

            var request = HTTPClientRequest(
                url: "\(httpURL)/topics/persistent/public/default/\(topic)"
            )
            request.method = .POST
            request.headers.add(name: "Content-Type", value: "application/json")
            request.body = .bytes(ByteBuffer(bytes: try PulsarRESTPublisher.produceBody(for: event)))
            let response = try await httpClient.execute(request, timeout: .seconds(15))
            #expect(response.status.code < 300, "produce failed with \(response.status)")

            #expect(try await collector.waitForCount(1, timeout: .seconds(30)))
            let record = await collector.received.first
            #expect(record?.event.eventId == "e-live-1")
            #expect(record?.event.payload["opportunityId"] == "o-1")
            #expect(record?.key == "opportunity-123", "partition key must survive the round trip")
            #expect(record?.redeliveryCount == 0)

            group.cancelAll()
        }
    }
}
```

Note: `PulsarRESTPublisher.produceBody` is `internal`, so add `@testable import ContextForwarder` if the direct call fails to resolve.

Wrap the whole test file body in `#if os(Linux)` for the same reason as Task 7, and make
the manifest entry platform-conditional too:

```swift
.testTarget(
    name: "ContextReceiverIntegrationTests",
    dependencies: [
        "ContextReceiver",
        "ContextForwarder",
        .target(name: "ContextReceiverWebSocket", condition: .when(platforms: [.linux])),
    ]
),
```

Verify afterwards that `swift test --filter ContextReceiverTests` still runs on macOS —
a test target that drags in a Linux-only module would break the entire macOS test run,
not just its own suite.

- [ ] **Step 3: Run it against a live broker**

```bash
docker compose -f docker-compose.pulsar.yml up -d
# Wait for readiness rather than sleeping blind:
until curl -sf http://localhost:8080/admin/v2/brokers/health >/dev/null; do sleep 2; done
docker run --rm --network host -v "$PWD":/src -w /src \
  -e PULSAR_HTTP_URL=http://localhost:8080 \
  swift:6.2-noble \
  bash -c 'swift test --filter ContextReceiverIntegrationTests 2>&1 | tail -30; exit ${PIPESTATUS[0]}'
echo "exit=$?"
```

Expected: `exit=0`, one test passing. **If produce returns 4xx**, the missing `valueSchema` field is the likely cause — record the exact broker response in the plan's follow-ups and add `valueSchema` to `produceBody` before continuing. Do not paper over it.

- [ ] **Step 4: Extend the CI filter to cover the new offline tests**

The workflow currently runs `swift test --filter DDDKitUnitTests` at lines 27 and 52, which excludes everything in this plan. Because `--filter` is an allowlist, adding service-free suites cannot pull in service-requiring ones:

```yaml
swift test --filter '(DDDKitUnitTests|EventSourcingTests|ContextForwarderTests|ContextReceiverTests)'
```

Run locally first to confirm the count and that nothing needs a service:

```bash
swift test --filter '(DDDKitUnitTests|EventSourcingTests|ContextForwarderTests|ContextReceiverTests)' 2>&1 | tail -5
```

- [ ] **Step 5: Document the module in the README**

Add a `ContextReceiver` section covering: the produce/consume payload asymmetry, why `pullMode` is mandatory, at-least-once plus host-side deterministic ids, the DLQ-as-park mapping, and the macOS limitation with its exact upstream cause (`WebSocketOutboundWriter.swift:210`, missing `@available`) so the next person does not rediscover it.

- [ ] **Step 6: Commit**

```bash
git add Tests/ContextReceiverIntegrationTests docker-compose.pulsar.yml Package.swift \
        .github/workflows/swift-build-testing.yml README.md
git commit -m "test: verify Pulsar round trip end to end"
```

---

## Follow-ups (not in scope)

- **Upstream fix for swift-websocket** — one `@available(macOS 26, iOS 26, tvOS 26, *)` on the `ByteBuffer` extension at `WebSocketOutboundWriter.swift:210`. Worth filing regardless of the pin decision, since it unblocks macOS for everyone. Owner declined to fork for now.
- **NotificationContext wiring** — the ACL translator (`OpportunityCollaboratorAdded.v1` → `IngestNotificationHandler`) and service composition belong in a separate plan in that repo; they are a different subsystem with their own tests.
- **`OCForwarding` should set `partitionKey`** to the opportunity id, otherwise Task 1's ordering capability goes unused in production.
- **`ForwarderGroupTests` sleep-ratio assertion** — still measures a ratio of two sleeps; the signal-based redesign remains unimplemented.
- **`ContextForwarder`/`ContextReceiver` import NIOCore without declaring it** — resolved transitively today. Same latent class of bug that broke the Linux build once already.
