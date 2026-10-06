# Design: `ForwardedRecord` carries KurrentDB custom metadata

**Date:** 2026-10-06
**Status:** Approved in conversation, pending implementation
**Related:** `2026-05-15-ambient-context-and-pluggable-metadata-design.md`（寫入側：應用層定義
`EventMetadata` struct，`KurrentStorageCoordinator.append` 把它 JSON encode 成 `EventData.customMetadata`）

---

## Context

ContextForwarder 把 KurrentDB persistent subscription 收到的事件包成 kit-agnostic 的
`ForwardedRecord` 交給 `ForwardingRule.translate`。目前 `ForwardedRecord(from: ReadEvent)` 只搬
`record.data`，`record.customMetadata` 在這一步被丟掉，所以 rule 永遠讀不到寫入側放進
metadata 的資訊。

驅動案例：OpportunityContext 的 `CollaboratorAdded`、`DesignatedUserAdded` 事件 payload 不帶操作者，
操作者 id 只在 customMetadata（`{"operatorId":"…"}`）。OC 的 PL forwarder 要寄「某某已邀請您…」、
「某某已將案件送出分配給您」這類通知，收件人或文案都需要操作者，但拿不到。

寫入側 spec 的原則是「framework 只給 marker protocol，schema 由應用層定義，read 端自己 decode」。
本 spec 是同一原則在 ContextForwarder 這條讀取路徑上的對應。

## Goals

- `ForwardedRecord` 帶出 customMetadata 原始 bytes。
- 提供泛型 `decodeMetadata<M: Decodable>(_:)`，由消費端指定 schema，形狀比照既有 `decodeBody(_:)`。
- Source-compatible：既有 `ForwardedRecord` 4 參數 init 的呼叫端（ddd-kit 測試 8 處、OC forwarder 測試）不用改。
- 失敗語意與 `decodeBody` 一致：資料損壞是 permanent，不是 transient。

## Non-Goals

- 不動 `ForwardingRule`、`ContextForwarder`、`ForwarderGroup` 的簽名；不把 metadata 型別做成
  `ContextForwarder` 的泛型參數（會是 breaking change，且把同一 forwarder 下所有 rule 綁死同一 schema）。
- 不在 ContextForwarder 內定義任何具體 metadata schema；`CustomMetadata` 留在 KurrentSupport。
- ContextForwarder target 不新增對 EventSourcing 的依賴，所以泛型約束是 `Decodable` 而非 `EventMetadata`
  （應用層的 metadata struct 本來就是 Codable）。
- 不涵蓋 OC forwarder 如何使用（wire event 加 `operatorId`、conformer 補 `recipients()`、人名查
  StaffContext）。那是 forwarder repo 的 bounded change，等本 spec 發版後另做。

---

## Design

### 1. 介面（`Sources/ContextForwarder/ForwardedRecord.swift`）

```swift
public struct ForwardedRecord: Sendable {
    public let eventType: String
    public let streamName: String
    public let eventId: String
    public let data: Data
    /// KurrentDB customMetadata 原始 bytes。寫入時沒帶 metadata（swift-kurrentdb 回空 Data）則為 nil，
    /// 「沒有」只有一種表示法。
    public let metadata: Data?

    public init(eventType: String, streamName: String, eventId: String, data: Data, metadata: Data? = nil)

    /// 以消費端指定的型別解 metadata。
    /// - `metadata == nil` → 回 nil，不是錯誤（上線前的舊事件、沒帶 metadata 的 context）。
    /// - 有 bytes 但不是合法 JSON，或缺 `M` 的必要欄位 → `ForwardingError.permanent`：
    ///   這些 bytes 重送也不會變得能解，retry 只是浪費，park 才會有人看到。
    ///   消費端若覺得某欄位可有可無，在自己的 `M` 裡宣告成 optional；寬鬆與否是型別定義的事，
    ///   不由 framework 猜。
    public func decodeMetadata<M: Decodable>(_ type: M.Type) throws -> M?
}
```

`init(from: ReadEvent)`（在 `ContextForwarder.swift` 的 extension）改為同時搬 `record.customMetadata`，
經正規化：空 `Data` → `nil`。正規化抽成 `static func normalizedMetadata(_ bytes: Data) -> Data?`，
讓它不需要構造 `ReadEvent` 就能單測。

`permanent` 的 reason 字串格式比照 `decodeBody`：
`"decoding metadata as \(M.self) from \(eventType) (\(eventId)) failed: \(error)"`。

### 2. 資料流

```
persistent subscription → ReadEvent
  → ForwardedRecord(from:)：data 照搬；customMetadata 空→nil，否則原樣帶上
  → rule.translate(record)
       ├─ 不關心 metadata 的 rule：完全不碰，零成本
       └─ 關心的 rule：let m = try record.decodeMetadata(MyMetadata.self)
            ├─ nil  → 自行決定（降級文案、空收件人、或丟 permanent）
            ├─ M    → 使用
            └─ throw permanent → 走既有 ForwardingDisposition → park
```

consume loop 不變。decode 只在 translate closure 裡發生，而且是 per-rule 自選。

### 3. 錯誤語意對照

| 情況 | 結果 | 理由 |
|---|---|---|
| `metadata == nil` | `nil` | 正常狀態，舊事件不能被卡住 |
| bytes 不是 JSON / 缺必要欄位 | `ForwardingError.permanent` | 與 `decodeBody` 一致；重送不會修好 |
| 解出來但值不合用（例：operatorId 空字串） | translate closure 自己判斷 | 業務規則，framework 不管 |

曾考慮「解不出來一律回 nil」：寫起來寬鬆，但會把資料損壞偽裝成「沒有 metadata」，forwarder 會靜默寄出
沒有操作者的通知，事後查不到原因。否決。

### 4. 測試（`Tests/ContextForwarderTests/ForwardedRecordTests.swift`，swift-testing）

- 有 metadata：`{"operatorId":"u-1"}` 解到測試用 `struct Op: Decodable { let operatorId: String }`。
- `metadata == nil`：`decodeMetadata` 回 nil。
- `normalizedMetadata(Data())` 回 nil；非空回原 bytes。
- 壞 bytes（`"not json"`）：丟 `.permanent`，reason 含 eventType 與 eventId。
- 缺必要欄位：用必填型別解 → `.permanent`；同一 bytes 用欄位 optional 的型別解 → 成功且欄位為 nil。
  這對測試證明寬鬆與否由消費端型別決定。
- 既有測試一行不改全綠：證明 source-compatible。

### 5. 文件與交付

- README 的 ContextForwarder 段落補 `decodeMetadata` 一句用法與失敗語意。
- `ForwardedRecord.swift` 頭註目前寫「deliberately carries NO timestamp」，補一段說明 metadata 為何帶
  raw bytes 而非 typed（kit-agnostic、per-rule schema）。
- 發 `1.4.0-beta.10`。OC forwarder 的 `Package.swift` 是 `from: "1.4.0-beta.9"`，升版後直接吃到。

## Files

- `Sources/ContextForwarder/ForwardedRecord.swift` — 加 `metadata`、`decodeMetadata`、`normalizedMetadata`、init 預設參數。
- `Sources/ContextForwarder/ContextForwarder.swift` — `init(from:)` 搬 `customMetadata`。
- `Tests/ContextForwarderTests/ForwardedRecordTests.swift` — 上述測試。
- `README.md` — ContextForwarder 段落。
