# A. `EventStore` 語意契約 — 設計

日期：2026-10-23（rev 5：generator import 改變改列 source-breaking；rev 4：依「減法」原則重寫，優先沿用既有機制）
系列：A（本份）→ B `2026-10-23-persistent-event-store-design.md` → C `2026-10-23-eventstore-ci-platform-design.md`。B、C 依賴本份。
版本：1.5.0。

## 1. 問題

`EventStore` 協定沒有說 revision 怎麼編號、`version: nil` 的意思、衝突丟什麼、`purge` 之後會怎樣。兩個現有實作的答案不同：

| 行為 | `KurrentStorageCoordinator` | `InMemoryStorageCoordinator` |
|---|---|---|
| revision | 0 起算 | 事件個數，1 起算 |
| `version: nil` | `.noStream` | 不檢查 |
| 衝突 | `KurrentError.wrongExpectedVersion` | `InMemoryStorageCoordinatorError.versionConflict` |
| `purge` | soft delete，不存在即丟錯 | 移除 key |
| 讀出順序 | 依 `occurred` 排序 | 寫入順序 |

單元測試替身與 production 語意不一致。另外 `EventTypeMapper`、`RecordedEventLike`、`CustomMetadata` 住在 KurrentSupport，非 Kurrent 的儲存無法重用生成的 mapper。

## 2. 目標 / 非目標 / 反目標

目標
- 寫下 `EventStore` 的契約。**以 `KurrentStorageCoordinator` 現行行為為準，只在兩個實作不一致的地方做決定**，不新增機制。
- 讓 `InMemoryStorageCoordinator`（改名 `InMemoryEventStore`）符合契約。
- 紀錄抽象下移到 EventSourcing。
- 一組 repo 內部共用的契約測試。

非目標
- 本機持久化（B 份）、CI 與平台（C 份）。
- link stream（JS projection 產出、以 `resolveLinks` 讀取的 stream）的語意。契約只涵蓋以 `id` 定址的 aggregate stream；`KurrentStorageCoordinator` 讀 link stream 的行為維持現狀。
- purge 對 `$ce-` 訂閱與 link stream 的影響。現行的 soft delete purge 已經會留下指向已刪事件的 link，這是既有問題，另開 issue，不在 1.5 範圍。
- 多 stream 原子 append、`UnitOfWork`。
- 物理抹除。
- 給下游自訂 `EventStore` 用的公開 conformance 套件。
- 改變 mapper 對解不回的事件的處理、generator 的事件形狀、metadata 解碼方式。

反目標
- 為了修一個問題而加一段新機制，而既有機制已足夠。

## 3. 契約

### 3.1 revision 與空 append
- 第一筆事件的 revision 是 `0`，之後遞增 1。（Kurrent 現行）
- 非空 `append` 成功時回傳寫入或冪等比對到的那段事件的最後 revision。
- `events` 為空是 no-op，優先於其他所有規則：不建立 stream、不檢查任何前提、回 `nil`。`EventSourcingRepository.save` 在沒有未提交事件時直接 return；`KurrentStorageCoordinator.append` 遇空陣列不打 client。

### 3.2 `fetchEvents(byId:)`
- stream 不存在或已 purge → `nil`。
- 事件依 **stream 回傳的順序**，不再額外排序。aggregate stream 的回傳順序就是 revision 順序；拿掉 `KurrentStorageCoordinator` 現有的 `occurred` 排序。
- mapper 回 `nil` → 靜默跳過；mapper 丟例外 → 跳過並記 warning。（Kurrent 現行，維持）契約測試只斷言紀錄被跳過，不斷言 log。
- `latestRevision` = 最後一筆被成功 map 的事件的 revision；沒有任何事件被 map → `nil`。（Kurrent 現行，維持）
  - 後果，寫進文件：尾端有 mapper 不認得的事件時，`find` 得到的 version 小於實際尾端，`save` 會衝突且重 `find` 也無法解決。這是防止舊程式寫在它看不懂的事件之後。要移除事件型別時應保留 mapping。

### 3.3 `fetchEvents(byId:afterRevision:)`
- 不存在或已 purge → `nil`。
- 回傳 revision 大於 `afterRevision` 的已 map 事件；`latestRevision` 為最後一筆回傳事件的 revision，沒有時等於 `afterRevision`。（Kurrent 現行，維持）
- `afterRevision` 必須是先前讀到或寫入時得到的 revision；其他值不在契約內。
- 協定預設實作維持現狀（以事件個數推算），它不符合 0 起算的本契約；文件註明自訂實作必須覆寫。repo 內三個實作 `InMemoryEventStore`、`KurrentStorageCoordinator`、`PersistentEventStore`（B 份）都覆寫它。

### 3.4 `append(events:byId:version:metadata:)`
- `version == nil`：要求 stream 不存在。`version == n`：要求 stream 尾端 revision `== n`。（Kurrent 現行）
- 已 purge 的 stream：非空 `append` 丟 `DDDError.streamPurged`。
- 不符 → `DDDError.commitConflict`。
- **冪等重送**：版本檢查失敗時，若本批事件 id 與 stream 中從預期位置起的同長度事件 id 完全相同，回傳那段的最後 revision、不寫入。這是 KurrentDB 既有的 id 去重；`InMemoryEventStore` 與 `InMemoryEventStoreClient` 以 id 比對照做。只涵蓋 `version` 為 `nil` 或指定值的情況。
- `commitConflict`、`streamPurged` 表示沒有寫入。其他錯誤（例如 KurrentDB 連線錯誤）可能已寫入；以同一批事件重送是安全的，由冪等重送保證。
- 同一批內出現重複事件 id 不在契約內：經由 `EventSourcingRepository` 不會發生，因為每個 `DomainEvent` 建立時就有新的 UUID。
- 單次 `append` 全成或全敗。兩個併發 `append` 帶同一個 `version`、不同事件 id → 恰好一成一敗。
- `metadata` 逐筆存下。經序列化的實作在讀取時，`RecordedEventLike.customMetadata` 就是寫入時的位元組，`nil` 對應 `Data()`。`event.metadata` 如何被填回維持 generator 現行行為，不在契約內。

### 3.5 `purge(byId:)`
- 呼叫後該 id 永久處於 purged 狀態：兩個 `fetchEvents` 回 `nil`，非空 `append` 丟 `streamPurged`。**不論呼叫前是否存在**，對不存在的 id 也一樣。重複呼叫靜默成功。
- `KurrentStorageCoordinator`：以 `tombstone(expectedRevision: .any)` 實作，重複 purge 得到的既有 `KurrentError.resourceDeleted` 視為成功。1.5 以前被 soft delete 的 stream 也會被 tombstone。
- `EventSourcingRepository.purge` 直接呼叫 `store.purge`，不再先 `find`。
- 資料不會被物理抹除，KurrentDB 保留到 scavenge。寫進 README。

### 3.6 錯誤
`DDDError.Code` 新增：

| code | 名稱 | payload |
|---|---|---|
| 501 | `commitConflict` | `DDDError.CommitConflict { id: String; expected: UInt64?; actual: UInt64? }`，`Equatable`，以 accessor `error.commitConflict` 讀取 |
| 502 | `streamPurged` | `id` |
| 503 | `storeUnavailable` | B 份使用 |
| 504 | `storeCorrupted` | B 份使用 |

`userInfos` 是診斷資訊，不得原樣回給終端使用者。

## 4. Kurrent 路徑的最小修改

- `KurrentStorageCoordinator` 直接 catch 兩種既有錯誤，不新增 seam 錯誤型別：
  - `KurrentError.wrongExpectedVersion` 與 `EventStoreClientError.wrongExpectedRevision` → `commitConflict`。
  - `KurrentError.resourceDeleted` → `fetchEvents` 回 `nil`、`append` 丟 `streamPurged`、`purge` 吞掉。
- `EventStoreClient` 新增 `tombstoneStream(name:)`，以協定擴充提供預設實作丟 `EventStoreClientError.tombstoneUnsupported`，既有外部 conformer 仍可編譯。`LiveEventStoreClient` 轉呼叫 `tombstone(.any)`。
- `InMemoryEventStoreClient`：
  - 新增 tombstone：記錄已 tombstone 的名字，之後對它的讀、寫、刪都丟 `KurrentError.resourceDeleted`，與真 server 一致。
  - `append` 加上 id 冪等，`.noStream` 與 `.at(n)` 兩種情況。
- **需要 swift-kurrentdb 一個 patch 版本**：`Streams.Read.send`（`Streams/Usecase/Specified/Streams.Read.swift:53-58`）目前把串流中途的 gRPC 錯誤原樣交給 continuation，沒經過既有的 `RPCError.rethrow`，所以讀取已 tombstone 的 stream 得到的是 `GRPCCore.RPCError`，而不是 `KurrentError.resourceDeleted`。修法是讓它沿用既有的 `rethrow` 對應，一行改動，不新增任何型別。DDDKit 的 swift-kurrentdb 下限提高到該 patch 版本，列入 §8。

## 5. `InMemoryEventStore`
- `InMemoryStorageCoordinator` 原地改名，舊名保留 deprecated typealias，訊息說明語意已變（0 起算、`nil` 要求新 stream、衝突改 `commitConflict`）。最早 1.6 移除。
- `InMemoryStorageCoordinatorError` 標 deprecated、不再丟出。
- 維持型別化、無 mapper、`recordedMetadata(byId:)`。
- repo 內依賴舊語意的使用處一起改：`samples/StatefulReadModelDemo`、`samples/PostgresReadModelDemo`、`ProjectorGeneratorFixture`、`Tests/ReadModelPersistenceTests/StatefulProjectorTests.swift`、`Tests/EventSourcingTests/EventSourcingRepositoryMetadataTests.swift`、`Tests/DDDKitUnitTests/EventSourcingRepositoryTests.swift`。

## 6. 紀錄抽象下移
- `RecordedEventLike`、`EventTypeMapper`、`CustomMetadata` 搬到 EventSourcing，定義不變。
- KurrentSupport 以 `public typealias` 維持舊名；`extension RecordedEvent: @retroactive RecordedEventLike`。
- generator 產出的 import 由 `KurrentSupport`／`KurrentDB` 改為 `EventSourcing`，其餘產出不變；`DomainEventGeneratorTests` 加一個鎖定 import 的 golden test。

## 7. 契約測試
- 新的**非 product** target `EventStoreContract`，依賴 EventSourcing。不 import Testing：每條規則是一個 `func check…<S: EventStore>(_ make: () async throws -> S) async throws`，違反時丟一個描述性錯誤。
- 各後端在自己的 test target 以一個 `@Test` 呼叫這些函式：
  - `InMemoryEventStore`、`PersistentEventStore`、`KurrentStorageCoordinator` + `InMemoryEventStoreClient` → 新 test target `EventStoreContractTests`。
  - `KurrentStorageCoordinator` + 真 KurrentDB → 新 test target `KurrentLiveContractTests`（C 份）。
- 需要「mapper 不認得的事件」的規則（§3.2 的跳過與 `latestRevision`），以 append 一個測試 mapper 不認得的事件型別產生，只對經序列化的後端執行。
- 每條規則使用新的 UUID 作為 id。

## 8. 相容性（1.5.0）

behaviour change
- `InMemoryStorageCoordinator`：0 起算、`nil` 要求新 stream、衝突改 `commitConflict`、purge 後的行為、冪等重送。
- `KurrentStorageCoordinator`：衝突改 `commitConflict`；空陣列不打 client 並回 `nil`；讀出不再依 `occurred` 排序；`purge` 改為 tombstone，對不存在的 id 也成功並使其永久 purged。
- `EventSourcingRepository.purge` 不再先 `find`，不存在的 id 不再丟 `aggregateNotFound`。
- `EventSourcingRepository.save` 無未提交事件時不呼叫 store。
- `InMemoryEventStoreClient`：tombstone、id 冪等。
- 自訂的 `EventStoreClient`（包括包住 `LiveEventStoreClient` 的 wrapper）必須實作或轉呼叫 `tombstoneStream`，否則 `KurrentStorageCoordinator.purge` 在執行時丟 `tombstoneUnsupported`。

source-breaking
- swift-kurrentdb 下限提高到 §4 所述的 patch 版本。
- generator 產出檔的 import 由 `KurrentSupport`／`KurrentDB` 改為 `Foundation`／`DDDCore`／`EventSourcing`（見 `GeneratedImports.swift`）。YAML 中以不再 import 的模組限定的型別（例如 `KurrentSupport.CustomMetadata`），或只有 KurrentSupport／KurrentDB 才提供的非限定型別，重新生成後編不過；KurrentSupport 的 typealias 無法補救，因為該模組根本沒被 import。處理方式：改寫為 `EventSourcing.CustomMetadata`（或非限定的 `CustomMetadata`），或在 `event-generator-config.yaml` 加上 `dependencies: [KurrentSupport]`。
- `DDDError.Code` 新增 501–504、`EventStoreClientError` 新增 `tombstoneUnsupported`：沒有 `default` 的 `switch` 會編不過。

source-compatible
- 三個型別下移（typealias；只對仍 import KurrentSupport 的程式碼有效）、`tombstoneStream` 有預設實作（編譯時會有 deprecation 警告）。

## 9. 減法紀錄
相對 rev 3，以下機制被移除，改由既有行為承擔：

| 移除的機制 | 改用 |
|---|---|
| link stream 的讀取位置、排序與 cursor 規則 | link stream 移出契約，維持現狀 |
| subscription 的 `unresolvedLink`、`systemEvents` 選項、遇解碼錯誤即 park | 既有問題，另開 issue |
| swift-kurrentdb 兩項前置條件 | `tombstone(.any)` 加既有的 `resourceDeleted`；只剩讀取路徑沿用既有 `rethrow` 的一行修正 |
| purge 不存在的 id 不留痕跡、legacy soft delete 遷移工具 | 一律 tombstone |
| seam 的錯誤正規化表與新錯誤型別 | coordinator 直接 catch 既有錯誤 |
| mapper 回 `nil` 與丟例外分流、`eventDecodingFailed` | 維持一律跳過 |
| generator 以 `CodingKeys` 排除 metadata、metadata 解碼 warning | 維持現行產出 |
| 批內重複 id 的 `invalidBatch` | 由 repository 的 UUID 保證，移出契約 |
| 傳輸錯誤的分類與 `storeUnavailable` 包裝 | 原樣丟出，靠冪等重送 |
| 協定預設 `afterRevision` 的新實作 | 維持現狀並註明適用範圍 |
| 公開的 `EventStoreConformance` product 與其 Testing 相依 | repo 內部 target，以丟錯回報 |
