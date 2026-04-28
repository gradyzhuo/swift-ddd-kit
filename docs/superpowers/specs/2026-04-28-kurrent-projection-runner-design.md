# Design: KurrentProjection.PersistentSubscriptionRunner

**Date:** 2026-04-28
**Status:** Approved (Phase 1)

## Context

目前使用 swift-ddd-kit 的應用層自行實作了「KurrentDB persistent subscription → 多個 `StatefulEventSourcingProjector`」的整合，產生大量重複樣板。觀察兩個現存的 application handler：

- `QuotingCasePostgresProjectionHandler`（152 行）— 訂閱 `$ce-QuotingCase`，dispatch 到 9+1 個 stateful projector
- `MonthlyRevenuePostgresProjectionHandler`（74 行）— 訂閱 `$ce-GetMonthlyRevenueStatistics`，dispatch 到 1 個 stateful projector

兩者重複的部分：

1. `start() { Task { ... } }` — fire-and-forget，無法 graceful shutdown
2. `subscribePersistentSubscription` + `for try await ... in subscription.events` 樣板
3. 錯誤處理：硬編碼 `if retryCount >= 5 { nack(.skip) } else { nack(.retry) }`
4. 「為一個 ID 跑一個 `StatefulEventSourcingProjector.execute(...)`」的 helper 方法每個都長得一樣

`swift-ddd-kit` 目前沒有任何 subscription 抽象（已 grep `Sources/`）。本 spec 描述在 `KurrentSupport` 新增 `KurrentProjection.PersistentSubscriptionRunner` 解決這個重複。

## Goals

- 抽掉 subscription event-loop / ack-nack 樣板
- 抽掉「dispatch event 到多個 stateful projector」樣板
- 用 structured concurrency（`run() async throws`）取代 fire-and-forget Task
- Retry policy 可配置，預設行為與既存 handler 一致（`MaxRetriesPolicy(max: 5)`）
- 對齊 KurrentDB 原生 nack action（`.retry / .skip / .park / .stop`），不簡化
- Subscription 連線失敗時直接 throw 出 `run()`，由 caller（ServiceGroup / TaskGroup）決定是否重啟
- Doc comment 明寫 eventual consistency 契約

## Non-Goals

- ❌ 不做 reconnect / supervisor — 由 caller 用 ServiceLifecycle 處理
- ❌ 不抽 catch-up subscription — 兩個現存 handler 都是 persistent，YAGNI
- ❌ 不抽 ID 解析 / event body decode — 各 case 規則差異太大，留給使用者用 closure 處理
- ❌ 不抽「`createPersistentSubscription`」— 假設 groupName 已在外部建立
- ❌ 不做 cross-projector transactional rollback — 見「Partial Failure Semantics」與「Phase 2 (Deferred)」
- ❌ 不抽 storage backend — persistent subscription 是 KurrentDB 專屬概念

## Module Placement

```
Sources/KurrentSupport/Adapter/
└── KurrentProjection.swift   ← 新增
```

放在 `Adapter/`（Clean Architecture 命名）下，與既有的 `KurrentStorageCoordinator.swift`、`EventTypeMapper.swift` 等並列。

`KurrentSupport` 名稱本身代表「所有 Kurrent 相關的 support」，能涵蓋 read-side 與 write-side 兩種職責，無需開新 module。

## Public API

```swift
import KurrentDB
import EventSourcing
import ReadModelPersistence
import Logging

public enum KurrentProjection {

    // MARK: - Runner

    public final class PersistentSubscriptionRunner: Sendable {

        public init(
            client: KurrentDBClient,
            stream: String,
            groupName: String,
            retryPolicy: any RetryPolicy = MaxRetriesPolicy(max: 5),
            logger: Logger = Logger(label: "KurrentProjection.PersistentSubscriptionRunner")
        )

        /// 註冊一個 stateful projector（高階常用 overload）。
        ///
        /// `extractInput` 回傳 `nil` = 此 event 不 dispatch 給這個 projector。
        @discardableResult
        public func register<Projector: EventSourcingProjector, Store: ReadModelStore>(
            _ stateful: StatefulEventSourcingProjector<Projector, Store>,
            extractInput: @Sendable @escaping (RecordedEvent) -> Projector.Input?
        ) -> Self
            where Store.Model == Projector.ReadModelType,
                  Projector.Input: Sendable

        /// 低階 escape hatch。需要客製 execute 邏輯時使用。
        ///
        /// 重要：`execute` 必須 idempotent — 框架在錯誤時會 nack(.retry) 觸發重送。
        @discardableResult
        public func register<Input: Sendable>(
            extractInput: @Sendable @escaping (RecordedEvent) -> Input?,
            execute: @Sendable @escaping (Input) async throws -> Void
        ) -> Self

        /// 阻塞執行直到：
        /// - 外部 `Task.cancel()` → 正常返回（不 throw `CancellationError`）
        /// - Subscription 連線失敗 / for-await 中斷 → throw
        /// - RetryPolicy 回傳 `.stop` → throw `RunnerStopped`
        public func run() async throws
    }

    // MARK: - Retry policy

    public protocol RetryPolicy: Sendable {
        func decide(error: Error, retryCount: Int) -> NackAction
    }

    public struct MaxRetriesPolicy: RetryPolicy {
        public let max: Int
        public init(max: Int = 5)
        // 行為：retryCount >= max → .skip，否則 .retry
    }

    public enum NackAction: Sendable {
        case retry
        case skip
        case park
        case stop
    }

    // MARK: - Errors

    public struct RunnerStopped: Error {
        public let reason: String
    }
}
```

### 內部結構

`final class` + `Sendable` + `OSAllocatedUnfairLock<[Registration]>` 包 closure list。

- `register` 是 sync chainable（return `Self`），內部用 lock 鎖 array
- 設計上是 register-before-run（doc 明寫），但 lock 確保即使 race 也安全
- Registration 內部結構：`struct Registration { let extract: ... ; let execute: ... }`，type-erased 成 `(RecordedEvent) async throws -> Void`
- 用 `OSAllocatedUnfairLock<T>`（Foundation, iOS 16+ / macOS 13+）而非 Swift `Mutex<T>`（後者需要 iOS 18+，超出 framework target）

## Execution Flow

```
run() 啟動
  │
  ▼
client.subscribePersistentSubscription(stream, groupName)
  │ throw → run() throw 出去（不 reconnect）
  ▼
for try await result in subscription.events {
    let record = result.event.record
    do {
        try await dispatch(record)
        try await subscription.ack(readEvents: result.event)
    } catch {
        try await handleFailure(error, result, retryCount: result.retryCount)
    }
}
```

### `dispatch(record:)`

```swift
try await withThrowingTaskGroup(of: Void.self) { group in
    for registration in registrations.snapshot() {
        group.addTask {
            guard let input = registration.extract(record) else { return }
            try await registration.execute(input)
        }
    }
    try await group.waitForAll()
}
```

並行執行所有有效註冊。任一 child throw → structured concurrency 自動 cancel 其餘 → `waitForAll()` rethrow。

### `handleFailure(_:_:retryCount:)`

```swift
let action = retryPolicy.decide(error: error, retryCount: retryCount)
do {
    switch action {
    case .retry: try await subscription.nack(readEvents: result.event, action: .retry, reason: "\(error)")
    case .skip:  try await subscription.nack(readEvents: result.event, action: .skip,  reason: "\(error)")
    case .park:  try await subscription.nack(readEvents: result.event, action: .park,  reason: "\(error)")
    case .stop:
        try await subscription.nack(readEvents: result.event, action: .stop, reason: "\(error)")
        throw RunnerStopped(reason: "RetryPolicy returned .stop after \(retryCount) retries: \(error)")
    }
} catch let nackError where !(nackError is RunnerStopped) {
    logger.error("nack failed for \(result.event.record.id): \(nackError)")
    // 繼續下一個 event（與既存 handler 行為一致）
}
```

### Cancellation

外部 `Task.cancel()`：
- for-await 被 Swift runtime 中斷 → break loop
- inflight TaskGroup 收到 cancellation → child 中止
- `run()` 正常返回（不 throw）

對齊 Swift Service Lifecycle 的 graceful shutdown 慣例。

## Partial Failure Semantics

**框架不提供 cross-projector rollback。** 行為是 at-least-once delivery + projector-level idempotency + eventual consistency。

### 場景：event N → A 成功、B/C 失敗

```
TaskGroup 啟動 A, B, C
├─ A 成功：寫入 store_A、cursor_A 推進到 revision(N)
├─ B 失敗：throw
└─ C 失敗：throw

→ TaskGroup throw → catch → RetryPolicy.decide → .retry → nack(.retry)
→ A 已 commit 的 Postgres 寫入無法 rollback
→ KurrentDB 稍後重送 event N
```

**重送 event N 時**（這是 `StatefulEventSourcingProjector` 的設計特性）：
- A：`fetchEvents(afterRevision: cursor_A)` 拿到空陣列 → 不寫 store → no-op
- B、C：cursor 還在 revision(N-1) → 拿到 event N → apply → 寫入

### 契約（doc comment 明寫）

> Register 的 `execute` 必須 idempotent。框架會在任一 projector 失敗時 nack 整個 event 觸發重送，已成功的 projector 會在重送時再次被呼叫，必須能無副作用回傳。
>
> 推薦使用 `StatefulEventSourcingProjector` 的高階 overload — 其 cursor 機制天然 idempotent。低階 overload 的使用者需自行確保 idempotency。

### 不能做「真正 rollback」的原因

| 方案 | 為何不可行 |
|---|---|
| 撤銷已成功的寫入 | Postgres 已 commit，沒有通用 compensating action |
| 跨 store 共享 transaction | 不同 store backend（PG / Redis / Mongo）transaction 模型不同；跨 backend 需 2PC |
| Sequential + fail-fast | 失敗點不變，只是慢 |
| 2PC / Saga | Framework 等級的另一個東西，超出本 spec 範圍 |

## Phase 2 (Deferred) — 已選定方向：Box C

**Box C：Postgres-specific 共享 transaction**（暫名 `KurrentProjection.PostgresTransactionalBox`）

利用「所有 read model 在同一 Postgres 實例」的假設，提供 per-event 共享 PG transaction，把 partial failure window 從「9 個 projector 之間」縮到「commit 那一瞬間」。

**前提是真的**：兩個現存 handler 都用 `PostgresJSONReadModelStore` + 共用 `pgClient`。

### Box 的價值（兩層，不只是 atomicity）

1. **執行語意**：把 partial failure window 從「N 個 projector 之間」縮到「commit 那一瞬間」。配合 cursor idempotency，重送時的「A no-op、B/C 重跑」變「A/B/C 一起重跑」— 重送語意更乾淨
2. **API-as-discipline**：Box 在 type system 上強迫使用者**做出選擇**——「這個 projection 要不要是 transactional 的」。沒有 Box 時，使用者預設掉進 eventual-consistency 而**沒有意識**；有 Box 時，使用者必須明確選 `register` 或 `register(transactional:)`，atomicity 變成顯性決策
   - 這是 API 設計的隱性教育價值：好的 API 不只是讓對的事容易做，也**讓錯的事被迫顯性**

### 為何仍分階段

1. **Scope 大** — 需動 `PostgresJSONReadModelStore`（接受共享連線 / transaction）、`StatefulEventSourcingProjector`（save 部分外部化讓 runner 控制提交時機）、整個 read side persistence layer 的 connection ownership
2. **即使有 box，commit 那一刻的網路斷線仍要靠 idempotency（cursor）救** — Box 是優化不是徹底解決，cursor 機制必須保留
3. **Phase 1 的 runner API 不需為 Phase 2 預留特殊參數** — Box 之後可附加性加入（見下方 API 草案），不破現有 contract
4. **Phase 2 自身設計問題還深**，需要獨立 brainstorm 才能定案

### Phase 2 大致 API 方向（**草案**，brainstorm 時再定稿）

```swift
// 高階 transactional overload，與 Phase 1 register 並存
extension KurrentProjection.PersistentSubscriptionRunner {
    @discardableResult
    public func register<Projector: EventSourcingProjector>(
        transactional projector: Projector,
        // store 的構造延後到 transaction 發生時才建立，使用 box 提供的連線
        storeFactory: @Sendable @escaping (PostgresTransaction) -> any TransactionalReadModelStore<Projector.ReadModelType>,
        extractInput: @Sendable @escaping (RecordedEvent) -> Projector.Input?
    ) -> Self
}
```

或包裝成獨立 type：

```swift
let runner = KurrentProjection.PostgresTransactionalRunner(
    client: kdbClient,
    pgPool: pool,
    stream: ...,
    groupName: ...
)
.registerTransactional(...) { tx in
    PostgresJSONReadModelStore<...>(transaction: tx)
}
.registerTransactional(...) { tx in ... }
```

兩種做法的 tradeoff（共存 vs 獨立 type）是 Phase 2 brainstorm 的主題之一。

### Phase 2 待解決設計問題

- `StatefulEventSourcingProjector` 是拆 `stage()` + `commit()`，還是接受外部 transaction context？對 Phase 1 非 box 使用者影響？
- PG 連線 / pool / transaction 由誰持有？runner 拿 pool？box 拿 connection？
- `ReadModelStore` 協定要不要加 `TransactionalReadModelStore` variant？
- 跨 backend 的 read model（如 PG + Redis）視為 Phase 2 non-goal 還是要處理？
- Phase 1 與 Phase 2 API 共存時，使用者怎麼從 type system 一眼看出「這條 runner 是不是 transactional」？避免半 transactional 半不是的混合誤用

## Migration Examples

### `MonthlyRevenuePostgresProjectionHandler`（74 行 → ~30 行）

```swift
import Foundation
import KurrentDB
import KurrentSupport
import QC_Universal
import ReadModelPersistencePostgres
import EventSourcing
import PostgresNIO

func makeMonthlyRevenueRunner(
    kdbClient: KurrentDBClient,
    pgClient: PostgresClient
) -> KurrentProjection.PersistentSubscriptionRunner {
    let projector = GetMonthlyRevenueStatisticsProjector(
        coordinator: .init(client: kdbClient, eventMapper: GetMonthlyRevenueStatisticsEventMapper())
    )
    let store = PostgresJSONReadModelStore<GetMonthlyRevenueStatistics>(client: pgClient)
    let stateful = StatefulEventSourcingProjector(projector: projector, store: store)

    return KurrentProjection.PersistentSubscriptionRunner(
        client: kdbClient,
        stream: "$ce-GetMonthlyRevenueStatistics",
        groupName: "monthly-revenue-postgres-projection"
    )
    .register(stateful) { record in
        guard record.streamIdentifier.name.hasPrefix("GetMonthlyRevenueStatistics-") else { return nil }
        let yearMonth = String(record.streamIdentifier.name.dropFirst("GetMonthlyRevenueStatistics-".count))
        let parts = yearMonth.split(separator: "-")
        guard parts.count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]) else { return nil }
        return GetMonthlyRevenueStatisticsInput(year: year, month: month)
    }
}

// 啟動：
try await makeMonthlyRevenueRunner(kdbClient: ..., pgClient: ...).run()
```

### `QuotingCasePostgresProjectionHandler`（152 行 → ~60 行）

```swift
func makeQuotingCaseRunner(
    kdbClient: KurrentDBClient,
    pgClient: PostgresClient
) -> KurrentProjection.PersistentSubscriptionRunner {
    let mapper = QuotingCaseAggregateEventMapper()

    func quotingCaseId(from record: RecordedEvent) -> String? {
        let name = record.streamIdentifier.name
        guard name.hasPrefix("QuotingCase-") else { return nil }
        return String(name.dropFirst("QuotingCase-".count))
    }

    func stateful<P: EventSourcingProjector, M: ReadModel & Sendable>(
        _ projector: P
    ) -> StatefulEventSourcingProjector<P, PostgresJSONReadModelStore<M>>
    where P.ReadModelType == M {
        StatefulEventSourcingProjector(
            projector: projector,
            store: PostgresJSONReadModelStore<M>(client: pgClient)
        )
    }

    return KurrentProjection.PersistentSubscriptionRunner(
        client: kdbClient,
        stream: "$ce-QuotingCase",
        groupName: "quoting-case-postgres-projection"
    )
    .register(stateful(GetOrganizationProjector(coordinator: .init(client: kdbClient, eventMapper: mapper)))) {
        quotingCaseId(from: $0).map(GetOrganizationInput.init)
    }
    .register(stateful(GetContactsProjector(coordinator: .init(client: kdbClient, eventMapper: mapper)))) {
        quotingCaseId(from: $0).map(GetContactsInput.init)
    }
    .register(stateful(GetAccountingTypeProjector(coordinator: .init(client: kdbClient, eventMapper: mapper)))) {
        quotingCaseId(from: $0).map(GetAccountingTypeInput.init)
    }
    // ... 其餘 6 個同形註冊
    .register(stateful(GetAdditionalQuotingUnitPriceRecordsProjector(coordinator: .init(client: kdbClient, eventMapper: mapper)))) { record in
        // 特例：key 從 event body decode
        guard record.eventType.hasPrefix("AdditionalQuotingUnit") else { return nil }
        struct Body: Decodable { let additionalQuotingUnitId: String }
        guard let body = try? JSONDecoder().decode(Body.self, from: record.data) else { return nil }
        return GetAdditionalQuotingUnitPriceRecordsInput(additionalQuotingUnitId: body.additionalQuotingUnitId)
    }
}
```

對比：原本每個 helper 方法 5–7 行純樣板（建構 projector / store / stateful / execute）→ 收成一行 `register`。`handleEvent` 整段 dispatch 邏輯消失（被 framework 的 `dispatch(record:)` 吸收）。`start()` 整段 subscription / ack / nack / retry 樣板消失。

## Open Items（實作時要解決）

1. `RecordedEvent` 在 `KurrentSupport.Adapter.RecordedEvent` 已有 typealias，確認 public 可見
2. `subscribePersistentSubscription` 的回傳型別 + nack `action:` 參數型別需與 KurrentDB Swift SDK 對齊（實作時 grep）
3. `Mutex` 用 Swift 6 Synchronization 的 `Mutex<T>`（macOS 15+ / iOS 18+ — 與 framework target 一致）
4. `RunnerStopped.reason` 是否要加 `lastError: any Error` 欄位 — 實作時看是否需要
5. Test：用 `TestCoordinator`（in-memory）寫單元測試 — 但 persistent subscription 本質要 KurrentDB，部分流程要走整合測試
6. Doc comment 補上 idempotency 契約

## Phase 1 → Phase 2 銜接點

Phase 1 ship 後，Phase 2 brainstorm 應該至少回答：
- Box 是不是 Postgres-only？跨 backend 的 read model 怎麼處理（Phase 2 non-goal？）
- `register` API 是新增 transactional variant 共存，還是包成獨立的 `PostgresTransactionalRunner`？決定的標準是「使用者能否在 type system 上一眼看出這條 runner 的 atomicity 等級」
- `StatefulEventSourcingProjector.execute` 拆 `stage` / `commit` 會不會影響 Phase 1 非 box 使用者？是否需要 backwards-compatible default？
- API 設計要強迫使用者顯性選擇「transactional / 非 transactional」（呼應 Box 的 API-as-discipline 價值），避免「忘記思考 atomicity」這個失誤模式
