# Local Event Store 與 `EventStore` 語意契約 — 索引

本 spec 在 2026-10-23 經兩輪對抗審查後拆成三份，請改讀：

| | 檔案 | 內容 |
|---|---|---|
| A | `2026-10-23-eventstore-contract-design.md` | `EventStore` 語意契約、conformance、`InMemoryEventStore`、紀錄抽象下移、Kurrent seam 與 tombstone、swift-kurrentdb 前置條件 |
| B | `2026-10-23-persistent-event-store-design.md` | `PersistentEventStore` 與 durable 測試 |
| C | `2026-10-23-eventstore-ci-platform-design.md` | CI、iOS、product、文件 |

B、C 依賴 A。全部落在 1.5.0。
