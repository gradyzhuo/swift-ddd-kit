# B. `PersistentEventStore` — 設計

日期：2026-10-23（rev 4：依「減法」原則重寫，以 Foundation 的 atomic write 取代自製 journal）
系列：A `2026-10-23-eventstore-contract-design.md`（本份依賴它）→ B（本份）→ C `2026-10-23-eventstore-ci-platform-design.md`。
版本：1.5.0。

## 1. 目標 / 非目標

目標
- 新 target 與 product `LocalEventStore`，提供 `PersistentEventStore`：以一個目錄為後盾，重啟後資料仍在，通過 A 份的契約測試。

非目標
- 多 stream 原子寫入。本設計每個 stream 一個檔案，無法讓多個檔案原子地一起更新；未來的 `UnitOfWork` 若要支援本機 store，需要它自己的機制。
- 斷電後的持久性保證（§5）。
- 大型 stream 的效能：每次 append 重寫整個 stream 檔案，適用於事件數量有限的 aggregate stream。
- 多 process 共用、App Group 等共享容器、雲端同步資料夾、網路檔案系統。
- 加密、完整性驗證。

## 2. API

```swift
public actor PersistentEventStore<StreamNaming: EventStreamNaming, Metadata: EventMetadata>: EventStore {
    public static func open(directory: URL, eventMapper: any EventTypeMapper) throws -> PersistentEventStore
    public func close()
}
```

- 依賴 EventSourcing 與 Foundation。`DDDKit` umbrella re-export `LocalEventStore`。
- stream 名稱由 `StreamNaming.getStreamName(id:)` 決定，與 Kurrent 路徑一致。
- 一個目錄只能有一個開啟中的 store instance（§6）。**讀寫兩端共用同一個 instance**：repository 與 projector 都持有同一個 `PersistentEventStore<Order, M>` 物件，projector 宣告 `typealias Store = PersistentEventStore<Order, M>`，事件由這個 store 的 mapper 解碼。這和 Kurrent 路徑上「每個 projector 自建一個 coordinator」的寫法不同，寫進文件。

## 3. 目錄與檔案

- `directory` 不存在時建立（含中間目錄）。不是 file URL 或指向一般檔案 → `storeUnavailable(reason: .invalidLocation)`。
- 每個 stream 一個檔案：`<directory>/<encoded stream name>.json`。編碼為 stream name 的 UTF-8 位元組的**小寫 hex**，在不分大小寫的檔案系統（macOS 預設）上也不會有兩個名字對到同一個檔案。UTF-8 超過 120 位元組的 stream name → `storeUnavailable(reason: .streamNameTooLong)`；這是本機 store 相對 KurrentDB 的已知限制。
- 讀取或 append 前比對檔案內的 `stream` 欄位與要求的名稱，不同 → `storeCorrupted`，不寫入。purge 不做這項檢查（§4）。
- 檔案內容：
  ```json
  {"formatVersion":1,"stream":"<name>","purged":false,
   "records":[{"eventId":"<UUID>","eventType":"<type>","payload":"<base64>","metadata":"<base64>"}]}
  ```
  `payload` 是 append 時 `JSONEncoder` 輸出的原始位元組，以 base64 保存以保證位元組不失真；`metadata` 無值時省略。record 的 revision 是它在陣列中的索引。
- 讀取時，record 經 `RecordedEventLike` 交給 mapper：`streamName` 為 stream name，`revision` 為索引，`customMetadata` 為 metadata 位元組或 `Data()`。

## 4. 操作

所有操作在 actor 內以同步檔案 I/O 執行，中間沒有 suspension point，因此同一個 store 上的操作天然序列化。

- **讀取**：讀整個檔案、解碼、交給 mapper（規則見 A 份 §3.2、§3.3）。只有「檔案不存在」（`ENOENT`）代表 stream 不存在 → `nil`；其他任何開檔或讀檔錯誤 → `storeUnavailable(reason: .io)`，append 遇到同樣的錯誤也不寫入。`purged == true` → `nil`。檔案無法解碼或 `formatVersion` 不是 1 → `storeCorrupted { stream }`，只影響該 stream。
- **append**：`events` 為空時依 A 份 §3.1 直接回 `nil`，不檢查名稱、不開檔、不檢查是否已 close。否則以與讀取相同的解碼讀出目前內容（解不開、`formatVersion` 不是 1 或 `stream` 不符 → `storeCorrupted`，不寫入）、依 A 份 §3.4 檢查、組出新內容，以 `Data.write(to:options: .atomic)` 整檔寫入。Foundation 先寫暫存檔再 rename，因此檔案只會是舊內容或新內容。寫入丟錯 → `storeUnavailable(reason: .io)`，檔案維持舊內容，**沒有寫入**。
- **purge**：不解碼既有檔案，一律以 atomic write 寫入 `{"formatVersion":1,"stream":"<name>","purged":true,"records":[]}`。因此 purge 也是壞檔（例如斷電後的空檔）唯一的 API 層修復方式。被 purge 的 payload 會從該 stream 檔中消失，但 purge 仍是邏輯刪除（A 份 §3.5）：atomic write 途中 crash 留下的暫存檔或已釋放的磁碟區塊仍可能含有 payload。
- 不快取：每次讀取與 append 前的檢查都從檔案解碼，契約測試因此一定經過磁碟上的格式。
- `fetchEvents(byId:afterRevision:)` 覆寫協定預設實作，依 A 份 §3.3。

## 5. 持久性

- process crash：每個檔案都是舊內容或新內容之一，不會半寫。
- OS crash 或斷電：`.atomic` 不呼叫 fsync，最近的寫入可能遺失；在某些檔案系統上，剛被取代的檔案可能變成空檔或內容損毀，讀取該 stream 時會得到 `storeCorrupted`，其他 stream 不受影響。寫進文件與 API doc comment。

## 6. 單一開啟者

- `open` 在 `<directory>/.lock` 上以 `open(2)`（`O_CREAT | O_CLOEXEC`）取得 fd，再 `flock(LOCK_EX | LOCK_NB)`。`EWOULDBLOCK` → `storeUnavailable(reason: .occupied)`；其他錯誤 → `storeUnavailable(reason: .io)`。`flock` 以 open file description 為單位，同一個 process 對同一目錄的第二次 `open` 也會失敗。
- `close()` 關閉 fd 並釋放鎖，冪等；之後任何操作丟 `storeUnavailable(reason: .closed)`。沒呼叫 `close()` 就被釋放時，deinit 關閉 fd。
- iOS 在 app suspended 時若仍持有共享容器內檔案的鎖會終止 app，因此禁止把目錄放在 App Group 等共享容器，寫進文件。

## 7. 測試（`LocalEventStoreTests`）
- 通過 A 份的契約測試（在 `EventStoreContractTests`）。
- 本 target 另測：
  - 寫入、`close`、重開、讀回。
  - 同一目錄第二次 `open` 失敗；`close` 後可開。
  - purge 後重開仍是 purged；解碼後 `records == []`，檔案位元組中不含原 payload 的 base64 字串與原 event id。
  - 某個 stream 的檔案損毀（截斷的 JSON、0 位元組檔案、`formatVersion` 不是 1、`stream` 欄位與名稱不符）→ 讀取與 `append`（`version` 為 `nil` 與指定值）都得到 `storeCorrupted` 且檔案位元組不變；`purge` 成功，之後讀取回 `nil`；其他 stream 不受影響。
  - 檔名恰為 `<stream name UTF-8 的小寫 hex>.json`；兩個只差大小寫的 stream name 各自寫入、讀回，互不干擾。
  - 一個 repository 與一個 projector 共用同一個 instance，projector 讀得到 repository 存下的事件。
  - stream name 過長 → `streamNameTooLong`。
  - `directory` 指向一般檔案 → `invalidLocation`。
- 每個案例使用獨立的 `temporaryDirectory/<UUID>`。

## 8. 減法紀錄
相對 rev 3，以下機制被移除：

| 移除的機制 | 改用 |
|---|---|
| append-only journal、0x0A 分隔、header 規則 | 每個 stream 一個 JSON 檔 |
| torn tail 截斷、重播驗證、fail-closed、`recovery` 模式、quarantine | `Data.write(.atomic)` 的 rename 原子性；壞檔只影響單一 stream |
| 寫入 rollback、`ftruncate`、poisoned 狀態 | atomic write 失敗時檔案不變 |
| `Durability` 兩種模式、`F_FULLFSYNC` | 不保證斷電持久性，寫進文件 |
| 開啟順序、inode 身分檢查、`creation` 選項、檔案保護設定 | 鎖放在獨立的 `.lock` 檔，資料檔不需要特殊開啟流程 |
| 一檔一 aggregate 型別、category 檢查 | 以完整 stream name 為檔名，一個 store 一個目錄 |
| 自訂 executor、記憶體索引與快取 | 每次 I/O 只動單一小檔，直接從檔案解碼 |
| `ReplayReport`、`journalCorrupted`、`journalUnsupportedVersion`、`storeClosed` | `storeCorrupted` 與 `storeUnavailable` 兩個 code |
| `@_spi` 檔案 I/O 注入點與故障注入測試 | 不需要：沒有 rollback 路徑可測 |
