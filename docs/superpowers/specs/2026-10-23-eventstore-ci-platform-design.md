# C. CI、平台與封裝 — 設計

日期：2026-10-23（rev 4：依「減法」原則重寫，只加契約與 iOS 支援所需的最小部分）
系列：A `2026-10-23-eventstore-contract-design.md` → B `2026-10-23-persistent-event-store-design.md` → C（本份，依賴 A、B）。
版本：1.5.0。

## 1. 目標 / 非目標

目標
- A 份的契約對真 KurrentDB 有一個 CI 檢查。
- 新 test target 被既有 CI 跑到。
- `DDDCore`、`EventSourcing`、`LocalEventStore` 成為 product，並確認能為 iOS 編譯。

非目標
- 讓 `KurrentSupportIntegrationTests` 等既有整合測試在 CI 上跑。
- 在 iOS Simulator 或 macOS 上執行測試。
- samples 的 CI。
- 把 iOS 消費者與 server 側相依圖隔離。

## 2. 既有 job
- 兩處 `--filter` 的 target 清單加入 `EventStoreContractTests` 與 `LocalEventStoreTests`。這兩個名稱不是任何其他 target 名稱的子字串。Swift Testing 的 `--filter` 也比對 suite 與 test 名稱，因此 `KurrentLiveContractTests` 裡的 suite 與 test 名稱不得包含 filter 中的任何一項。

## 3. Kurrent 契約 job（新增）
- `ubuntu-latest`，單一工具鏈（既有矩陣中最新的 `6.4`）。
- 以既有 TestUtility 的 pooled 入口連線：
  ```
  docker run -d --name kurrentdb -p 2113:2113 \
    -e KURRENTDB_CLUSTER_SIZE=1 -e KURRENTDB_INSECURE=true \
    docker.kurrent.io/kurrent-latest/kurrentdb:<26.1 的完整 patch 版本>
  ```
  `KURRENTDB_POOL_URLS: '["esdb://admin:changeit@localhost:2113?tls=false"]'` 寫在 job 層級的 `env:`，不用 shell `export`，讓後續每個 step 都讀得到。輪詢 `http://localhost:2113/health/live` 最多 60 秒後執行 `swift test --filter KurrentLiveContractTests`。
- `KurrentLiveContractTests` 必須包含「purge 後讀取回 `nil`」，用來驗證 A 份 §4 的 swift-kurrentdb patch。
- image 版本寫進 changelog，作為 A 份「Kurrent 現行行為」的參考 server；升級它時要重新跑一次並 review。
- 這個 job 先不列入 required checks，由維護者在它穩定後決定。

## 4. 平台與 product
- `Package.swift` 的 `platforms` 加 `.iOS(.v18)`。
- 新增三個 `.library` product：`DDDCore`、`EventSourcing`、`LocalEventStore`。
- 這三個 target 只依賴彼此、Foundation 與 swift-log（EventSourcing 現有相依）。
- 新增一個 job：`macos-15`，對三個 product 各跑一次 `xcodebuild build -scheme <product> -destination 'generic/platform=iOS Simulator'`。
- `EventStoreContract`（A 份 §7）是內部 target，不是 product；加入 `scripts/emit-symbol-graphs.sh` 的排除清單。`LocalEventStore` 照一般 module 進 symbol graph。

## 5. 相容性（本份新增的部分）
- source-breaking：`.iOS(.v18)` 使所有 product 的 iOS 最低版本變成 18。影響以 iOS 為目標使用本 package 任一 product 的消費者。
- source-compatible：新增三個 product。

## 6. 文件
- README、CLAUDE.md、`docs/index.html` 的模組表：加入 `LocalEventStore`；`InMemoryStorageCoordinator` 改為 `InMemoryEventStore`；三個型別移到 EventSourcing；說明 purge 會讓該 id 永遠無法再寫入（`append` 丟 `streamPurged`，會重用的 id 不要 purge），KurrentDB 保留資料到 scavenge，`LocalEventStore` 則從檔案中移除 payload。
- 遷移指南放在既有 `docs/migration/` 下，起點是 1.5.0 發布時最近一個穩定版：若 1.4.0 已發布，寫 1.4 → 1.5；若 1.4.0 尚未發布，寫 1.3 → 1.5，並一併涵蓋 1.4 beta 期間已合併的變更。內容彙整 A、B、C 三份的 behaviour change、source-breaking 與遷移步驟。
- A、B 兩份中每一項標註「寫進文件」的內容都要進 README 或 `LocalEventStore` 使用說明。至少包括：支援 iOS 的 product；一個目錄一個 store instance，repository 與 projector 共用同一個 instance；只放在 sandbox 內的 Application Support 這類位置，不支援共享容器、雲端同步資料夾、網路檔案系統；斷電持久性的限制與 purge 修復壞檔的方式；尾端有不認得的事件時 `save` 會一直衝突，移除事件型別時要保留 mapping。

## 7. 減法紀錄
相對 rev 3，以下機制被移除：

| 移除的機制 | 理由 |
|---|---|
| Postgres service、`KurrentSupportIntegrationTests` 上 CI | 不是本 spec 要驗的東西 |
| 雙工具鏈、試用期計數、release gate、`workflow_dispatch` | 單一工具鏈的契約 job 即可驗證契約，是否 required 交給維護者 |
| 測試數大於 0 的檢查、錨定 regex | 新 target 名稱不會被誤選 |
| macOS 測試 job、iOS Simulator 測試執行、xcresult 解析 | B 份已沒有平台相依的檔案邏輯，只需確認可編譯 |
| `EventStoreConformance` product 與 `import Testing` spike | A 份改為內部 target、以丟錯回報 |
| `GeneratorIsolationFixture` | generator 的 import 改以 golden test 鎖定 |
| samples job | samples 在 A 份的 PR 中一起修改 |
| iOS 指南的多數章節 | 對應的機制已移除 |
