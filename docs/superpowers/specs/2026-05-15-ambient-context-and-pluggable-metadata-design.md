# Design: Ambient Context & Pluggable Metadata for Event Sourcing

**Date:** 2026-05-15
**Status:** Pending review
**Supersedes ideas from:** `/Users/gradyzhuo/Desktop/plan-ambient-context.md`(早期 plan,本 spec 為與現有 codebase 整合過後的版本)

---

## Context

目前 `EventSourcingRepository.save(aggregateRoot:, external: [String:String]?)` 跟 `EventStore.append(...,external: [String:String]?)` 透過一個固定的字串 dict 通道把 audit-style metadata(operatorId、userId 等)從應用層帶到儲存層。三個問題:

1. **Domain 抽象被 infrastructure metadata 汙染**:Repository 是 domain 概念,`external` dict 是 infra 概念,每個 Usecase 都要從入口顯式傳遞這個值,跟 business invariant 無關
2. **Schema 鎖死在 dict 形態**:`[String:String]?` 限制了所有使用者只能用 dict;`tenantId`、`requestId`、`causationId` 等需求沒擴充空間
3. **跟現有 `DomainEvent.Metadata` 機制重複**:codebase 已經有 `DomainEvent` 帶 `associatedtype Metadata: Codable` + `var metadata: Metadata? { set get }`,read-side(ReadModel / Projector)透過 `event.metadata` 拿值。但 write-side 的 `external` 跟它沒接起來

本 spec 解決方案:
- **Ambient context propagation**:用 `@TaskLocal` 從 Usecase 入口往下傳 metadata,domain 層完全不接觸
- **Pluggable schema**:應用層自己定義 `EventMetadata`-conforming struct,framework 只提供 marker protocol
- **與既有 `DomainEvent.metadata` 整合**:write 端從 ambient 拿 typed metadata,write 到 KurrentDB `customMetadata` bytes;read 端由 mapper 把 bytes 解碼後填回 `event.metadata`,ReadModel 透過 `event.metadata` 拿值,跟現在一樣

---

## Goals

- 新增 `EventMetadata: Codable & Sendable` marker protocol
- 新增 `EventMetadataContext<M: EventMetadata>` generic `@TaskLocal` 容器
- 修改 `EventStore` protocol:加 `associatedtype Metadata: EventMetadata`,`append` 收 typed `metadata: Metadata?`,**移除** `external: [String:String]?` 參數
- 修改 `EventSourcingRepository.save`:**移除** `external: [String:String]?` 參數,default impl 改讀 `EventMetadataContext<Store.Metadata>.current`
- 修改 `KurrentStorageCoordinator`:加 `Metadata: EventMetadata` generic param,`append` 把 typed metadata JSON encode 後寫 `EventData.customMetadata`
- 既有 `CustomMetadata` struct 加 `: EventMetadata` conformance,當作 default schema(generator 預設輸出的 `typealias Metadata = CustomMetadata` 不變)
- Mapper 內部負責在 read 路徑把 `RecordedEvent.customMetadata` bytes 解碼後填回 `event.metadata`(per-event-type 處理,既有 generator 邏輯)
- 更新 samples + tests + docs

## Non-Goals

- ❌ **不動** `DomainEvent` protocol(`associatedtype Metadata` 跟 `var metadata` 保留)
- ❌ **不動** `AggregateRoot` / `Usecase` / `DomainEventBus`
- ❌ **不動** `DomainEventGenerator` template(generator 仍輸出 `typealias Metadata = CustomMetadata`)
- ❌ **不**在 framework 內定義任何具體 metadata schema(原 plan §0.4)
- ❌ **不**做 compile-time `Store.Metadata == event.Metadata` 強約束(靠 convention,runtime 容錯)
- ❌ **不**支援「同次 save 內不同 event 套用不同 metadata」(99% 場景一個 command → N events 共用同份 metadata)
- ❌ **不**改 `EventStore.fetchEvents` 的回傳 tuple 形狀(plan 原本想改成 `AsyncThrowingStream<StoredEvent>`,本 spec 維持現有 `(events: [any DomainEvent], latestRevision: UInt64)?`)
- ❌ **不**引入新的 envelope 型別(`StoredEvent` 不必要 — 既有 `DomainEvent.metadata` 已經是 envelope)
- ❌ **不**在 `EventTypeMapper` protocol 上加 `mapMetadata` hook(per-event-type 的 metadata decode 由 mapper 內部處理,既有 generator 已負責)

---

## Architectural Approach

### 核心 insight:write/read 路徑由 store 邊界匯合

```
Write 路徑:
  UseCase
    → EventMetadataContext<M>.$current.withValue(metadata)   ← ambient 設定
        → Repository.save(aggregateRoot:)                      ← domain 層,zero metadata 感知
            → save default impl 讀 EventMetadataContext<Store.Metadata>.current
            → store.append(events:, ..., metadata: typed)
                → KurrentStorageCoordinator: JSON encode metadata → EventData.customMetadata bytes
                  (event.metadata 在 write 端被忽略,write-only-from-ambient)

Read 路徑:
  Repository.find / Projector.execute
    → store.fetchEvents(byId:)
        → KurrentStorageCoordinator: 從 KurrentDB 拉 RecordedEvent
        → EventTypeMapper.mapping(eventData: record):
            - decode event payload → 具體 event struct
            - decode record.customMetadata bytes → 具體 Metadata
            - event.metadata = decoded                         ← 整合點
            - return event
    → [any DomainEvent](每個 event.metadata 都已填好)
    → ReadModel / consumer 透過 event.metadata 拿值
```

### 責任分層(對比原 plan §0.1)

| 角色 | 知道 metadata schema? | 知道底層 store 型別? |
|---|---|---|
| `AggregateRoot` / `DomainEvent` | ❌ 不在 framework 約束之列 | ❌ |
| `Usecase` | ✅ 自己定義 + 設 ambient | ❌ |
| `EventSourcingRepository` 實作 | ✅(透過 `Store.Metadata`) | ✅ |
| `EventStore` 實作(`KurrentStorageCoordinator`) | ✅(透過 generic param) | ✅ |
| ddd-kit framework 本身 | ❌(只規範 marker protocol) | ❌ |

### `DomainEvent.metadata` 在新設計裡的角色

- **Write 端**:被 storage 忽略。應用層創建 event 時不需要設(設了會被 ambient 覆蓋的結果蓋掉)
- **Read 端**:由 mapper 在解碼時填入。Read-side consumer(ReadModel / Projector apply)透過它拿到所有 ambient 設定的內容
- 語意要在 doc comment 寫明,避免使用者誤用為 write-side input

### 型別一致性靠 convention(不靠 compile time)

| 位置 | 預期一致 |
|---|---|
| `EventMetadataContext<M>.current` | `M == Store.Metadata` |
| `EventStore.Metadata` | = generator 產出 event 的 `typealias Metadata` |
| `DomainEvent.Metadata`(per event) | 慣例同 `Store.Metadata`(generator 預設 `CustomMetadata`) |

實際對齊由應用層 / generator 維持,framework 不強制。Runtime 不對齊時 mapper decode 失敗 → `event.metadata = nil`,不 crash。

---

## Module Placement

### `Sources/DDDCore/` — **不動**

`DomainEvent.swift` 完全不動。`AggregateRoot`、`Repository`、`Usecase`、`DomainEventBus` 不動。

### `Sources/EventSourcing/` — 新增 + 修改

**新增**:
- `EventMetadata.swift` — `protocol EventMetadata: Codable, Sendable {}` marker
- `EventMetadataContext.swift` — `enum EventMetadataContext<M: EventMetadata> { @TaskLocal static var current: M? }`

**修改**:
- `EventStorageCoordinator/EventStorageCoordinator.swift`(現存) — `EventStore` protocol 加 `associatedtype Metadata`,`append` 簽章換 typed `metadata` 參數
- `EventStorageCoordinator/InMemoryStorageCoordinator.swift`(現存) — `InMemoryStorageCoordinator<Metadata: EventMetadata>` 加 generic param,內部 storage 同時記錄 metadata
- `EventSourcingRepository.swift`(現存) — `save` 簽章移除 `external`,default impl 讀 ambient
- `Projector/EventSourcingProjector.swift`(現存) — `apply(readModel:events:)` 簽章不動,但實作上 events 已自帶 `event.metadata`,projector 可選擇是否使用

### `Sources/KurrentSupport/` — 修改

- `Adapter/EventTypeMapper.swift` — protocol 簽章不動,生成的 mapper 內部要新增 metadata decode + assign
- `Adapter/KurrentStorageCoordinator.swift` — 改成 `KurrentStorageCoordinator<StreamNaming, Metadata: EventMetadata>`;`append` JSON encode typed metadata 寫 `customMetadata`;fetchEvents 維持現狀(mapper 內部處理 metadata)
- `Adapter/CustomMetadata.swift` — 加 `: EventMetadata` conformance(一行);`external`、`operatorId` extension 都保留(route Q)
- `Adapter/RecordedEvent.swift` — `mappingClassName` 保留(infra need);`userId` extension 保留(application convenience,跟 CustomMetadata.operatorId 對齊)

### `Sources/DomainEventGenerator/` — **基本不動**

- `Generator/Event/EventStructureGenerator.swift` 仍輸出 `typealias Metadata = CustomMetadata` 跟 `var metadata: Metadata?`
- Mapper 生成器需要在 per-event case 加入 metadata decode 邏輯(現在可能已經有,實作時 verify)

---

## Protocol & Type Signatures

### `EventMetadata`(新)

```swift
// Sources/EventSourcing/EventMetadata.swift

/// Marker protocol for application-defined event metadata schemas.
///
/// Applications define concrete metadata structs by conforming to this protocol.
/// The framework defines no schema fields.
///
/// Example:
/// ```swift
/// struct AuditMetadata: EventMetadata {
///     let operatorId: String
///     let tenantId: String
/// }
/// ```
public protocol EventMetadata: Codable, Sendable {}
```

### `EventMetadataContext<M>`(新)

```swift
// Sources/EventSourcing/EventMetadataContext.swift

/// Ambient TaskLocal carrier for event metadata, parameterised by the metadata
/// schema. Each concrete `M` has an independent storage slot.
///
/// Set at Usecase entry:
/// ```swift
/// try await EventMetadataContext<AuditMetadata>.$current.withValue(audit) {
///     try await repository.save(aggregateRoot: order)
/// }
/// ```
///
/// Read in `EventSourcingRepository.save` default impl via
/// `EventMetadataContext<Store.Metadata>.current` — typed, no runtime cast.
public enum EventMetadataContext<M: EventMetadata> {
    @TaskLocal public static var current: M?
}
```

### `EventStore`(修改現存)

```swift
// Sources/EventSourcing/EventStorageCoordinator/EventStorageCoordinator.swift

public protocol EventStore: Sendable {
    associatedtype Metadata: EventMetadata                            // ← 新增

    func fetchEvents(byId id: String) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)?
    func fetchEvents(byId id: String, afterRevision revision: UInt64) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)?

    func append(
        events: [any DomainEvent],
        byId id: String,
        version: UInt64?,
        metadata: Metadata?                                            // ← 取代 external
    ) async throws -> UInt64?

    func purge(byId id: String) async throws
}

extension EventStore {
    public func fetchEvents(byId id: String, afterRevision revision: UInt64) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)? {
        guard let result = try await fetchEvents(byId: id) else { return nil }
        let newEvents = Array(result.events.dropFirst(Int(revision)))
        return (events: newEvents, latestRevision: result.latestRevision)
    }
}
```

### `EventSourcingRepository`(修改現存)

```swift
// Sources/EventSourcing/EventSourcingRepository.swift

public protocol EventSourcingRepository<Store>: Repository {
    associatedtype Store: EventStore                                   // unchanged

    var store: Store { get }

    func find(byId id: AggregateRootType.ID) async throws -> AggregateRootType?
    func save(aggregateRoot: AggregateRootType) async throws           // ← 移除 external
    func delete(byId id: AggregateRootType.ID) async throws            // ← 移除 external
    func purge(byId id: AggregateRootType.ID) async throws
}

extension EventSourcingRepository {
    public func save(aggregateRoot: AggregateRootType) async throws {
        let metadata = EventMetadataContext<Store.Metadata>.current    // ← typed read,無 as?
        let latestRevision = try await store.append(
            events: aggregateRoot.events,
            byId: aggregateRoot.id,
            version: aggregateRoot.version,
            metadata: metadata
        )
        if let latestRevision {
            aggregateRoot.update(version: latestRevision)
        }
        try aggregateRoot.clearAllDomainEvents()
    }

    public func delete(byId id: AggregateRootType.ID) async throws {
        guard let aggregateRoot = try await find(byId: id) else {
            throw DDDError.aggregateNotFound(
                usecase: "DeleteAggregateRoot",
                aggregateRootType: AggregateRootType.self,
                aggregateRootId: "\(id)"
            )
        }
        try aggregateRoot.markDelete()
        try await save(aggregateRoot: aggregateRoot)
    }

    public func purge(byId id: AggregateRootType.ID) async throws {
        guard let _ = try await find(byId: id) else {
            throw DDDError.aggregateNotFound(...)
        }
        try await store.purge(byId: id)
    }
}
```

### `KurrentStorageCoordinator`(修改現存)

```swift
// Sources/KurrentSupport/Adapter/KurrentStorageCoordinator.swift

public final class KurrentStorageCoordinator<
    StreamNaming: EventStreamNaming,
    Metadata: EventMetadata                                            // ← 新增 generic
>: EventStore {
    let logger = Logger(label: "KurrentStorageCoordinator")
    let eventMapper: any EventTypeMapper
    let client: KurrentDBClient

    public init(client: KurrentDBClient, eventMapper: any EventTypeMapper) {
        self.eventMapper = eventMapper
        self.client = client
    }

    public func append(
        events: [any DomainEvent],
        byId id: String,
        version: UInt64?,
        metadata: Metadata?
    ) async throws -> UInt64? {
        let streamName = StreamNaming.getStreamName(id: id)
        let metadataBytes: Data? = try metadata.map { try JSONEncoder().encode($0) }

        let eventDataList = try events.map { event in
            try EventData(
                id: event.id,
                eventType: event.eventType,
                model: event,
                customMetadata: metadataBytes ?? Data()
            )
        }

        let stream = client.streams(specified: streamName)
        let response = try await stream.append(events: eventDataList) {
            $0.expectedRevision = version.map { .at(UInt64($0)) } ?? .any
        }
        return response.currentRevision.flatMap { UInt64($0) }
    }

    public func fetchEvents(byId id: String) async throws
        -> (events: [any DomainEvent], latestRevision: UInt64)? {
        // 內部從 KurrentDB 拉 RecordedEvent → mapper.mapping(eventData:) → events with metadata filled
        // 邏輯與現有版本一致,只是 mapper 內部多了 metadata decode 步驟
    }

    // fetchEvents(byId:afterRevision:) 跟 purge 不變
}
```

### `EventTypeMapper`(現有 protocol 不動,generated mapper 加 metadata decode)

```swift
// Sources/KurrentSupport/Adapter/EventTypeMapper.swift — 不動
public protocol EventTypeMapper: Sendable {
    func mapping(eventData: RecordedEvent) throws -> (any DomainEvent)?
}

// Generated mapper(範例):
struct OrderEventMapper: EventTypeMapper {
    func mapping(eventData record: RecordedEvent) throws -> (any DomainEvent)? {
        let decoder = JSONDecoder()
        let className = record.mappingClassName
        switch className {
        case "OrderCreated":
            var event = try decoder.decode(OrderCreated.self, from: record.data)
            if let metaBytes = record.customMetadata, !metaBytes.isEmpty {
                event.metadata = try? decoder.decode(OrderCreated.Metadata.self, from: metaBytes)
            }
            return event
        case "OrderShipped":
            var event = try decoder.decode(OrderShipped.self, from: record.data)
            if let metaBytes = record.customMetadata, !metaBytes.isEmpty {
                event.metadata = try? decoder.decode(OrderShipped.Metadata.self, from: metaBytes)
            }
            return event
        default:
            return nil
        }
    }
}
```

`try?` 在 metadata decode 是刻意的容錯:應用層 metadata 解碼失敗不該丟掉整個 event。

### `CustomMetadata`(現有,加一行 conformance)

```swift
// Sources/KurrentSupport/Adapter/CustomMetadata.swift

public struct CustomMetadata: Codable, Sendable, EventMetadata {       // ← + EventMetadata
    public let className: String
    public var external: [String: String]?
    // operatorId extension 不動
}
```

### `InMemoryStorageCoordinator`(修改現存)

```swift
public actor InMemoryStorageCoordinator<Metadata: EventMetadata>: EventStore {
    // 內部 storage 同時 carry events + 對應的 metadata 序列
    // append: 把 typed metadata 跟 events 一起記下
    // fetchEvents: 重建 events,並且把記下的 metadata 透過 event.metadata setter 填回
    // 跟 KurrentStorageCoordinator 邏輯對齊,差別在於底下不是真的 KurrentDB
}
```

---

## Data Flow Examples

### Write 路徑 — 完整範例

```swift
// 應用層定義
struct AuditMetadata: EventMetadata {
    let operatorId: String
    let tenantId: String
}

// 對應的 events typealias Metadata = AuditMetadata
struct OrderCreated: DomainEvent {
    typealias Metadata = AuditMetadata
    var metadata: AuditMetadata?
    let id: UUID
    let aggregateRootId: String
    let occurred: Date
    let customerId: String
}

// Repository
final class OrderRepository: EventSourcingRepository {
    typealias AggregateRootType = Order
    typealias Store = KurrentStorageCoordinator<OrderStreamNaming, AuditMetadata>
    let store: Store

    init(store: Store) { self.store = store }
}

// Usecase 入口設定 ambient
struct PlaceOrderUsecase: Usecase {
    let repository: OrderRepository

    func execute(input: Input) async throws -> Output {
        let metadata = AuditMetadata(
            operatorId: input.operatorId,
            tenantId: input.tenantId
        )
        return try await EventMetadataContext<AuditMetadata>.$current.withValue(metadata) {
            let order = try Order(id: input.orderId, customerId: input.customerId)
            try await repository.save(aggregateRoot: order)
            // ↑ default save 讀 EventMetadataContext<AuditMetadata>.current
            // ↑ store.append(events: order.events, ..., metadata: ambient)
            // ↑ KurrentStorageCoordinator encode metadata → EventData.customMetadata
            return Output(orderId: order.id)
        }
    }
}
```

### Read 路徑 — 完整範例

```swift
// ReadModel 透過 event.metadata 拿 audit 資訊
struct OrderActivityReadModel: ReadModel {
    var lastOperator: String?
    var lastTenant: String?
}

func apply(readModel: inout OrderActivityReadModel, events: [any DomainEvent]) {
    for event in events {
        if let created = event as? OrderCreated, let meta = created.metadata {
            readModel.lastOperator = meta.operatorId
            readModel.lastTenant = meta.tenantId
        }
    }
}

// Projector.execute(input:) → store.fetchEvents → mapper 把 event.metadata 填好回來 →
// projector 拿 [any DomainEvent] 套 apply,event.metadata 內容跟 write 時 ambient 一致
```

---

## Edge Cases / Error Semantics

| 情境 | 行為 |
|---|---|
| 沒設 ambient context(`EventMetadataContext<M>.current == nil`) | `metadata` 是 nil → KurrentDB customMetadata 寫空 → read 回來 `event.metadata = nil` |
| Write 時應用層手動設了 `event.metadata` | **忽略**;`KurrentStorageCoordinator.append` 不讀 `event.metadata`,只用傳入的 `metadata:` 參數 |
| Read 時 `record.customMetadata` 解碼失敗 | Mapper 用 `try?`,失敗就 `event.metadata = nil`;logger.warning;事件本身仍回傳 |
| Read 時 event payload 解碼失敗 | 既有行為:mapper 回 nil,`KurrentStorageCoordinator` 跳過該 event;logger.warning |
| `Store.Metadata` 跟 `event.Metadata` 型別不同 | Compile 不擋;runtime mapper decode 失敗 → `event.metadata = nil`;算「使用錯誤但不 crash」 |
| `Task.detached` 內的 save | TaskLocal 不繼承 → ambient 為 nil → metadata 為 nil。需要明確 capture + re-apply |
| Nested `withValue` | 內層覆蓋外層,離開內層後回到外層值(TaskLocal 預設語意) |

---

## Testing Strategy

### 新增

1. **`EventMetadataContextTests`**(`Tests/EventSourcingTests/`)
   - `withValue` 內可以讀到設定值
   - Nested `withValue` 能正確 override
   - 結束後 context 回到 nil
   - 結構化 task (`async let`、`TaskGroup`) 繼承 context
   - `Task.detached` **不**繼承 context(明確驗證)

2. **`EventSourcingRepositoryMetadataTests`**(`Tests/EventSourcingTests/` 或 `Tests/DDDKitUnitTests/`)
   - 自訂測試用 `TestMetadata: EventMetadata`
   - 自訂測試用 Repository,其 `Store.Metadata == TestMetadata`
   - 用 in-memory store 驗證:
     - 設 `EventMetadataContext<TestMetadata>.$current.withValue(...)` → `repository.save` → store 收到正確 typed metadata
     - 沒設 ambient → metadata 為 nil(不 crash)
     - Read 路徑 → events 回來 `event.metadata` 內容跟原 ambient 相符

3. **`KurrentMetadataRoundtripTests`**(`Tests/KurrentSupportIntegrationTests/`,需 KurrentDB)
   - Ambient → write → KurrentDB customMetadata bytes → read → `event.metadata` 內容相符

### 修改既有

- 所有呼叫 `repository.save(aggregateRoot:, external: [...])` 的測試,改成 `EventMetadataContext<CustomMetadata>.$current.withValue(.init(className: ..., external: [...])) { try await repository.save(aggregateRoot: ...) }`
- `KurrentStorageCoordinator` 既有測試:把 `external: [...]` 改成 `metadata: CustomMetadata(...)`
- `InMemoryStorageCoordinator` 既有測試:加 metadata 軸驗證

### 測試紀律

- `swift build` 無 warning
- `swift test` 全綠
- 每個改動檔案有對應測試覆蓋

---

## Execution Order(獨立 commits)

訊息符合 repo 既有 `[CATEGORY] description` 風格。

1. **`[FEATURE] Add EventMetadata protocol and EventMetadataContext<M>`**
   - 純新增 `Sources/EventSourcing/EventMetadata.swift` + `EventMetadataContext.swift`
   - 加 `EventMetadataContextTests`
   - Zero impact 到其他 code

2. **`[FEATURE] CustomMetadata conforms to EventMetadata`**
   - 一行 conformance
   - 確認既有 tests 不破

3. **`[REFACTOR] EventStore.append accepts typed metadata; remove external param`**
   - `EventStore` protocol 加 `associatedtype Metadata`,append 簽章換
   - `InMemoryStorageCoordinator`、`KurrentStorageCoordinator` 同步修改
   - 對應的 store-level tests 改寫
   - Breaking change(commit message 標註)

4. **`[REFACTOR] EventSourcingRepository.save reads EventMetadataContext`**
   - `save` / `delete` 簽章移除 `external`
   - Default impl 讀 `EventMetadataContext<Store.Metadata>.current`
   - 既有 Repository tests 改寫(用 `withValue` 包起來)
   - Breaking change

5. **`[REFACTOR] Update generated mapper to populate event.metadata`**
   - `DomainEventGenerator/Generator/Mapper/...` 在 per-event case 加 metadata decode + assign(若 generator 尚未產出此邏輯)
   - 既有 generated mapper 跟著重新生成

6. **`[REFACTOR] Update samples to ambient-context pattern`**
   - `samples/KurrentProjectionDemo`、`samples/KurrentTransactionalProjectionDemo` 等改用 `EventMetadataContext.$current.withValue`

7. **`[DOCS] Document ambient context + EventMetadata pattern`**
   - README:Core Concepts 後新增 section
   - CLAUDE.md:加 "Event Metadata Pattern" 段
   - MIGRATION.md:遷移步驟(Repository 移除 `external`、Usecase 用 ambient)

---

## Open Questions

無 — brainstorming 階段已收斂。實作時可能浮現的細節:

- **`KurrentStorageCoordinator` 既有 `eventMapper: any EventTypeMapper` 是 type-erased**。若加 `Metadata` generic 後 mapper 想跟 store 的 Metadata type 對齊,可能 mapper 也要 generic(否則 mapper 內 `event.metadata = try decoder.decode(OrderCreated.Metadata.self, ...)` 跟 store 的 Metadata 沒有 compile-time 連結)。實作時:**保持 mapper type-erased**,Metadata 對齊依然走 convention(per generated mapper 內部 decode 成 per-event-type 的 Metadata,跟 `Store.Metadata` 對齊由 generator / 應用層維持)
- **InMemoryStorageCoordinator 多 generic param 後,既有測試的 `typealias Storage = InMemoryStorageCoordinator` 需指定型別**(`InMemoryStorageCoordinator<CustomMetadata>` 或測試用 `Empty` struct)
- **`RecordedEvent.userId` extension 的去留**(目前 read `customMetadata.external["userId"]`)。Route Q 下 CustomMetadata 保留,extension 也保留;但若應用層用自訂 Metadata schema,該 extension 對它們沒意義。文件需註明此 extension 只在 CustomMetadata-as-Metadata 場景有意義

---

## Risk Notes

1. **TaskLocal 在 `Task.detached` 不繼承**(原 plan §7.1):若 framework 內部有 detached task 經過 metadata 邊界,需手動 capture + re-apply。實作時 audit `Sources/` 內所有 `Task.detached` 用法
2. **同次 save 共用一份 metadata**(原 plan §7.2):刻意設計。若未來真要 per-event override,在 `KurrentStorageCoordinator.append` 內部留擴充空間(目前所有 events 共用 `metadataBytes`,未來可改成 mapper 提供 per-event encode hook)
3. **CustomMetadata.external 仍是 dict**:應用層自訂 Metadata 時不要繼承這個習慣。文件需註明 `CustomMetadata` 是 "預設 schema" 而非 "推薦 schema"
4. **`event.metadata` write 端被忽略的語意**:容易誤用。doc comment 在 `DomainEvent` 跟 `KurrentStorageCoordinator.append` 兩處都要寫清楚

---

## Definition of Done

- [ ] `EventMetadata` protocol 新增,只有 `Codable + Sendable`
- [ ] `EventMetadataContext<M>` 新增,generic per `M`
- [ ] `EventStore` protocol 加 `associatedtype Metadata`,`append` 取代 `external` 為 `metadata: Metadata?`
- [ ] `EventStore.fetchEvents` 回傳 tuple 形狀不變
- [ ] `EventSourcingRepository.save` 移除 `external`,default impl 讀 ambient
- [ ] `KurrentStorageCoordinator` 加 `Metadata` generic param,append 序列化 typed metadata 寫 customMetadata bytes
- [ ] `CustomMetadata` 加 `: EventMetadata` conformance
- [ ] `InMemoryStorageCoordinator` 加 `Metadata` generic param,內部 carry typed metadata
- [ ] Generated mapper 在 per-event case 把 `record.customMetadata` decode 後 assign 到 `event.metadata`
- [ ] 至少一個 `samples/` 更新為 ambient context pattern
- [ ] 新增測試:`EventMetadataContextTests`、`EventSourcingRepositoryMetadataTests`、`KurrentMetadataRoundtripTests`
- [ ] 既有測試全綠,`swift build` 無 warning
- [ ] README / CLAUDE.md / MIGRATION.md 更新
- [ ] 每個 step 獨立 commit,訊息符合 repo 風格
- [ ] **API 洩漏檢查**:`Sources/EventSourcing/` 內沒有 `RecordedEvent`、`EventData` 等 Kurrent 型別出現在 public API
