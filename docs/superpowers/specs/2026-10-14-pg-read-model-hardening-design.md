# Design: Postgres read model hardening before first production use

**Date:** 2026-10-14
**Status:** Approved in conversation, pending spec review
**Related:**
`2026-04-03-postgres-read-model-store-design.md`、
`2026-04-28-kurrent-projection-runner-design.md`、
`2026-04-29-transactional-subscription-runner-design.md`

---

## Context

NotificationContext（NC）要用 `KurrentProjection.TransactionalSubscriptionRunner` +
`PostgresTransactionalReadModelStore` 建跨通知查詢的 read model（寫進共用 snapshot 表，查詢由
NC 自己用 JSONB SQL 寫）。這套程式碼自 1.0.0 起就在 tag 裡、有整合測試與 sample，但除了 ddd-kit
自己的測試外沒有任何使用者——NC 會是第一個 production 使用者。上線前盤點出以下問題：

1. **舊快照覆蓋新快照**：兩個 Postgres store 的 `save` 都是無條件 `ON CONFLICT DO UPDATE`。
   兩個 consumer（多 instance，或 nack 重投亂序）處理同一 id 時，先寫的 rev 6 會被後 commit 的
   rev 5 蓋回去，直到該 stream 有新事件才修正。
2. **runner 不建／不重建 subscription group**：兩個 runner 直接 `subscribePersistent`，group 不存在
   就一直丟錯。「缺 group 就重建」目前只有 `ContextForwarder`（2026-10-08 KurrentDB 重建事故後補的）有。
3. **read model schema 演進沒有重建流程**：snapshot 是 Codable JSON，改必填欄位／換型別後舊 snapshot
   decode 失敗 → 無限 nack。需要「清 snapshot + group 重設到開頭」的流程。
4. 小項：(a) `PostgresTransactionalReadModelStore` 表名寫死；(b) snapshot 的 `type` 欄位用
   `String(describing: Model.self)`，Swift 型別改名舊資料就對不到。
5. **Generator 產生的 `apply()` 遇到未列出的事件會中止整段 fold**：
   `ProjectorGenerator` 產出 `default: return`，同批後面的事件全被略過，revision 卻照樣前進，
   之後永遠補不回來。只要 read model 只列部分事件、卻 fold 完整 aggregate stream 就會踩到
   （NC 的 `NotificationDeliveryView` fold `Notification-{id}` 即是）。

此外 `TransactionalSubscriptionRunner.dispatch` 用 `TaskGroup` 讓多個 projector 並行在同一條
`PostgresConnection` 上下查詢，順手改成依序執行。

**前提（使用者明定）**：Postgres snapshot 只是投影暫存，不是事實來源，不負責寫入修改。任何異常
（schema 變更、模式切換、資料損壞）的修復方式都是「清掉、從頭重跑」。

## Goals

- 兩個 Postgres store 提供可選的寫入模式：`overwrite`（現行）與 `monotonic`（只接受更新的 revision），
  預設 `monotonic`；兩種模式在結構上使用不同的表，切換時不會彼此複用。
- 兩個 runner 預設確保 subscription group 存在（不存在就建，`startFrom: .start`、`resolveLink: true`），
  執行中發現 group 消失會重建並把錯誤拋給呼叫方重啟。
- 跟儲存後端無關的 snapshot 清除抽象 + 放在 `KurrentProjection` 的重建編排，Postgres 是其中一種實作。
- read model 可宣告穩定的 type 名稱；`PostgresTransactionalReadModelStore` 表名可設定。
- Generator 產生的 `apply()` 遇到未列出的事件只跳過該筆。
- 文件：Get Started（從零到可查詢的 Postgres read model）、寫入模式、schema 演進與重建。

## Non-goals

- 通用查詢 API、JSONB 索引（由應用層自己的 migration 處理）。
- 依 schema 版本自動重建（見 Future work）。
- Kurrent stream 版的 snapshot store（見 Future work；本設計的抽象已預留位置）。
- `PersistentSubscriptionRunner` 的 dispatch 並行度（各 store 獨立，維持並行）。

---

## 1. Store 層

### 1.1 寫入模式與表名

`ReadModelPersistencePostgres` 新增：

```swift
public enum SnapshotWriteMode: Sendable {
    /// Unconditional upsert. Table = base name.
    case overwrite
    /// Only a strictly newer revision replaces the stored row. Table = base name + "_monotonic".
    case monotonic
}
```

表名由單一內部函式依 `(baseTableName, writeMode)` 推得：

| writeMode | 實際表名（base = `read_model_snapshots`） |
|---|---|
| `.overwrite` | `read_model_snapshots` |
| `.monotonic` | `read_model_snapshots_monotonic` |

- identifier 驗證（沿用現有 regex）與 Postgres 63 字元上限檢查都對**加完後綴的實際表名**做，
  違反時 `precondition` 失敗（與現行 `PostgresJSONReadModelStore` 一致）。
- 兩種模式結構上不可能寫到同一張表，滿足「切換時不複用」。

### 1.2 Store 介面

```swift
PostgresJSONReadModelStore<Model>(client:, tableName: String = "read_model_snapshots",
                                  writeMode: SnapshotWriteMode = .monotonic)
PostgresTransactionalReadModelStore<Model>(tableName: String = "read_model_snapshots",
                                           writeMode: SnapshotWriteMode = .monotonic)
PostgresReadModelMigration.createTable(on:, tableName: String = "read_model_snapshots",
                                       writeMode: SnapshotWriteMode = .monotonic)
```

`PostgresTransactionalReadModelStore()` 不帶參數仍可編譯（4a）。

### 1.3 monotonic 的 SQL

```sql
INSERT INTO <table> (id, type, data, revision, updated_at)
VALUES ($1, $2, $3::jsonb, $4, now())
ON CONFLICT (id, type) DO UPDATE SET
    data = EXCLUDED.data, revision = EXCLUDED.revision, updated_at = EXCLUDED.updated_at
WHERE <table>.revision < EXCLUDED.revision
```

- revision 較舊或相同的寫入被靜默略過：交易照常 commit、事件照常 ack。這是正確結果——每次寫入都是
  「從事件折疊到某 revision 的完整狀態」，保留 revision 最大者即正確。被略過時記 debug log
  （以 affected row count == 0 判斷）。
- 選條件式 upsert 而非 `SELECT ... FOR UPDATE`：`PostgresJSONReadModelStore` 不在交易內，`FOR UPDATE`
  無效；第一次建立時資料列不存在，鎖不到。
- `overwrite` 維持現行 SQL（既有的 last-write-wins 行為）。適用於單一 consumer 且依序投遞，或需沿用既有
  `read_model_snapshots` 表。（KurrentDB 的 hard delete 會留下 tombstone、stream 無法重建；soft delete 後再寫入
  revision 仍持續累加，因此「revision 從 0 重來」不會發生；且 runner 以 `stored.revision` 增量折疊，
  overwrite 也無法解決 revision 重置。）

### 1.4 穩定的 type 名稱（4b）

`EventSourcing.ReadModel` 新增 customization point：

```swift
public protocol ReadModel: Codable {
    associatedtype ID: Hashable
    var id: ID { get }
    static var readModelTypeName: String { get }
}
extension ReadModel {
    public static var readModelTypeName: String { String(describing: Self.self) }
}
```

兩個 Postgres store 的 `type` 欄位改用 `Model.readModelTypeName`。預設值與現行相同，既有程式零修改。
變更 `readModelTypeName` 等同 schema 變更，須走重建流程。

### 1.5 相容性

只用預設參數的呼叫方，表名從 `read_model_snapshots` 變為 `read_model_snapshots_monotonic`（新表為空，
須重建）。目前只有 ddd-kit 自己的測試與 samples 受影響，本次一併修正。寫進 release note。

---

## 2. Snapshot 清除抽象

### 2.1 `ReadModelPersistence`（後端無關）

```swift
/// A snapshot backend that can drop every snapshot of the given read model types at once.
/// Used by `KurrentProjection.rebuild` — snapshots are a disposable projection cache,
/// so recovery from any schema change is "purge, then replay from the start".
public protocol ReadModelSnapshotPurging: Sendable {
    func purgeSnapshots(ofTypes typeNames: [String]) async throws
}
```

- `InMemoryReadModelStore` 實作：`typeNames` 包含 `Model.readModelTypeName` 時清空全部 storage。
  重建流程的單元測試因此不需要 PG。

### 2.2 `ReadModelPersistencePostgres`

```swift
public struct PostgresReadModelSnapshots: ReadModelSnapshotPurging {
    public init(client: PostgresClient, tableName: String = "read_model_snapshots",
                writeMode: SnapshotWriteMode = .monotonic)
    // DELETE FROM <resolved table> WHERE type = ANY($1)
}
```

表名推算與 store 共用 §1.1 的函式。

### 2.3 Future：Kurrent stream 版 snapshot store

以 Kurrent stream 存 snapshot（例如每個 read model 一條 snapshot stream、讀最後一筆）時，只要實作
`ReadModelStore` + `ReadModelSnapshotPurging`，即可套用同一套重建流程。本次不做。

---

## 3. Runner 層

### 3.1 `EventStoreClient` seam 擴充

```swift
public struct PersistentSubscriptionSettings: Sendable {
    public enum StartPosition: Sendable { case start, end }
    public var startFrom: StartPosition = .start
    public var resolveLink: Bool = true
    public init(startFrom: StartPosition = .start, resolveLink: Bool = true)
}

public protocol EventStoreClient: Sendable {
    // ...existing...
    /// Creates the group; an already-existing group is tolerated (settings are not changed).
    func ensurePersistentSubscription(stream: String, group: String,
                                      settings: PersistentSubscriptionSettings) async throws
    /// Deletes the group; a missing group is tolerated.
    func deletePersistentSubscription(stream: String, group: String) async throws
}

public enum EventStoreClientError {
    // ...existing...
    case subscriptionGroupNotFound(stream: String, group: String)
}
```

- `LiveEventStoreClient`：
  - ensure → `persistentSubscriptions(stream:group:).create { resolveLink; revision = .start/.end }`，
    只吞 `KurrentError.resourceAlreadyExists`（與 `ContextForwarder.ensureSubscription` 相同）。
  - delete → `.delete()`，只吞 `.resourceNotFound`。
  - subscribe 時 `KurrentError.resourceNotFound` 轉成 `.subscriptionGroupNotFound`（判斷方式同
    `ContextForwarder.isMissingGroup`），runner 因此不依賴 `KurrentError`。
- `$ce-` 系統 stream 的 `resolveLink = true` 從「使用者自己記得」變成 ensure 的預設。

### 3.2 `InMemoryEventStoreClient`

- 新增明確的 group 登記表，記錄每個 group 的 settings。
- `ensure` 實作 `startFrom`：`.start` 重播既有事件（現行行為）；`.end` 只收之後的事件。
- `delete` 移除 group，既有 session 的 event stream 以 `.subscriptionGroupNotFound` 結束。
- 新增 `init(requireExplicitGroups: Bool = false)`：
  - `false`（預設）：subscribe 時自動建 group（`.start`），與現行一致，既有測試不受影響。
  - `true`：subscribe 到不存在的 group 丟 `.subscriptionGroupNotFound`，用於測試 runner 的建立／重建邏輯。

### 3.3 Runner 設定

```swift
extension KurrentProjection {
    public enum SubscriptionSetup: Sendable {
        /// Ensure the group exists before subscribing, and recreate it if it disappears.
        case ensure(PersistentSubscriptionSettings)
        /// The caller manages the group (pre-1.4.0-beta.12 behavior).
        case manual
    }
}
```

兩個 runner 的所有 init（含 `PostgresSupport` 的 convenience init）新增
`subscriptionSetup: SubscriptionSetup = .ensure(.init())`（即 `.start` + `resolveLink`）。

`run()`：

1. `.ensure` 時先 `ensurePersistentSubscription`。
2. `subscribePersistent` 並消費（既有邏輯不變）。
3. 若 subscribe 或消費過程拋 `.subscriptionGroupNotFound` 且為 `.ensure`：記 warning →
   以同 settings `ensurePersistentSubscription` → 把原錯誤再拋出，由呼叫方（ServiceGroup 等）重啟。
   與 `ContextForwarder` 一致，也守住 runner「不自動重連」的既有契約。因 `startFrom` 預設 `.start`，
   重建後從頭重播；revision cursor（+ monotonic）使重播成為 no-op。
4. `.manual`：完全維持現行行為。

### 3.4 依序 dispatch

`TransactionalSubscriptionRunner.dispatch(record:transaction:)` 從 `TaskGroup` 改為依註冊順序逐一
`await`。所有 projector 共用同一條連線，依序才不會有同連線並行查詢；任一失敗即停止，整筆 rollback，
語意不變。`PersistentSubscriptionRunner` 維持並行。

---

## 4. 重建編排

`KurrentSupport`（與 runner 同處，subscription 生命週期本在這裡）：

```swift
extension KurrentProjection {
    public static func rebuild(
        readModels: [any ReadModel.Type],
        snapshots: any ReadModelSnapshotPurging,
        eventStore: any EventStoreClient,
        stream: String,
        group: String,
        settings: PersistentSubscriptionSettings = .init(startFrom: .start),
        logger: Logger = Logger(label: "KurrentProjection.rebuild")
    ) async throws
    // + overload taking `client: KurrentDBClient`
}
```

順序：

1. `deletePersistentSubscription(stream:group:)`——先切斷 group，就算有漏停的 consumer 也不會再拿到事件。
2. `snapshots.purgeSnapshots(ofTypes: readModels.map { $0.readModelTypeName })`。
3. `ensurePersistentSubscription(stream:group:settings:)`。

每一步都是冪等的，中途失敗直接重跑。同一 group 下未列出的 read model 也會被重播，revision cursor
使其成為 no-op。

**操作程序**（寫進文件）：停掉所有 consumer → 執行 rebuild → 部署新版。若 consumer 沒停且為
`.ensure`，它可能在步驟 1 後自行以 `.start` 重建 group，結果仍收斂（從頭重播），但新舊版本並存期間
舊版可能用舊 schema 寫入，因此程序要求先停。

---

## 5. Generator 修正

`Sources/DomainEventGenerator/Generator/Model/ProjectorGenerator.swift` 產生的 `apply()`：
`default: return` → `default: continue`。產生程式碼的行為改變，寫進 release note。

---

## 6. 文件

DocC catalog（`documentation.yml` 會自動收）：

- `Sources/ReadModelPersistencePostgres/ReadModelPersistencePostgres.docc/`
  - landing page
  - **Getting Started**：建表 → 定義 `ReadModel`（含 `readModelTypeName`）→ projector →
    `TransactionalSubscriptionRunner`（`.ensure` 預設）→ 放進 ServiceGroup 執行 → 用 JSONB SQL 查詢
    → 重建。程式碼與 `samples/PostgresReadModelDemo` 對齊。
  - **Snapshot write modes**：overwrite vs monotonic、表名規則、何時用哪個、切換要重建。
- `Sources/ReadModelPersistence/ReadModelPersistence.docc/`
  - landing page
  - **Schema evolution and rebuilding**：snapshot 是可丟棄的暫存；不需重建的變更（加 optional 欄位）；
    需要重建的變更（必填、換型別、改 `readModelTypeName`、切 `writeMode`、換表名）；操作程序；
    為什麼不能只清表（group checkpoint 已在後面，沒有新事件的 id 永遠不會被重建）。
- 所有新公開 API 都有 symbol doc。
- `README.md`：新增 Postgres read model 小節（精簡 Get Started + 連到 DocC）。
- `docs/index.html`：v1.4 release 卡片補上本次項目；Guides 區加 Getting Started 連結。
- `CLAUDE.md`：架構段補 `SnapshotWriteMode`、`ReadModelSnapshotPurging`、`SubscriptionSetup`、
  `KurrentProjection.rebuild`。
- `samples/PostgresReadModelDemo`、`samples/KurrentTransactionalProjectionDemo` 改用新 API／預設表名。

---

## 7. 測試

- **PG 整合**（`ReadModelPersistencePostgresIntegrationTests`）：
  - monotonic 拒絕較舊／相同 revision、接受較新（兩個 store 各一）
  - overwrite 無條件覆蓋
  - 兩種模式寫入不同的表；`createTable` 依 mode 建表
  - 自訂 `readModelTypeName` 生效；transactional store 自訂表名
  - 表名含後綴超過 63 字元被拒
  - `PostgresReadModelSnapshots.purgeSnapshots` 只刪指定 type
- **Runner 單元**（`KurrentSupportUnitTests` / `KurrentSupportInMemoryTests`，`requireExplicitGroups: true`）：
  - `.ensure` 自動建 group 並收到事件
  - group 被刪 → runner 重建 group 並拋 `.subscriptionGroupNotFound`；重跑後繼續消費
  - `.manual` 對不存在的 group 直接拋錯、不建立
  - `startFrom: .end` 不重播既有事件
  - transactional dispatch 依註冊順序、第一個失敗後不再執行後續 projector
- **重建單元**：`KurrentProjection.rebuild` + `InMemoryReadModelStore` + `InMemoryEventStoreClient`
  ——rebuild 後從頭重播、snapshot 重新生成；未列出的 type 不被清除。
- **KurrentDB 整合**（`KurrentSupportIntegrationTests`，拋棄式容器，advertise 對應 mapped port，
  不碰 `:2113` dev DB）：Live ensure（已存在被容忍）、delete（不存在被容忍）、
  `resourceNotFound` → `.subscriptionGroupNotFound`、rebuild 端到端（PG + KurrentDB）。
- **Generator**（`DomainEventGeneratorTests`）：產出含 `default:\n                continue`；
  行為測試——未列出的事件夾在中間，後面列出的事件仍被套用。

## 8. 發佈

- 單一分支 `feat/pg-read-model-hardening`、單一 PR、base `main`，分多個 commit。
- merge 後 tag `1.4.0-beta.12`。
- Release note 註明三個行為變更：
  1. Postgres store 預設 `monotonic`，預設表名改為 `read_model_snapshots_monotonic`
  2. runner 預設 `.ensure`，會自動建立／重建 subscription group（`startFrom: .start`）
  3. generator 產生的 `apply()` 不再因未列出的事件中止 fold

## Future work

- 依 schema 版本自動重建（meta 表記版本 + advisory lock + rolling deploy 處理）。
- Kurrent stream 版 snapshot store（§2.3）。
