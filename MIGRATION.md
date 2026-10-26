# Migration Guide: DDDKit → swift-ddd-kit

本文件整理從 `DDDKit` 遷移至 `swift-ddd-kit` 的所有破壞性變更，幫助現有專案快速完成升級。

---

## Package 層級變更

### Package 名稱

```diff
- .package(url: "https://github.com/gradyzhuo/DDDKit.git", from: "0.1.1")
+ .package(url: "https://github.com/gradyzhuo/swift-ddd-kit.git", from: "<new-version>")
```

> Package name 從 `"DDDKit"` 改為 `"swift-ddd-kit"`，但 library product 名稱 `"DDDKit"` 不變，`import DDDKit` 不受影響。

### KurrentDB 依賴升級

```diff
- .package(url: "https://github.com/gradyzhuo/KurrentDB-Swift.git", from: "1.10.0")
+ .package(url: "https://github.com/gradyzhuo/swift-kurrentdb.git", from: "2.0.0")
```

如果你的專案直接引用 KurrentDB，target dependency 也需同步更新：

```diff
- .product(name: "KurrentDB", package: "kurrentdb-swift")
+ .product(name: "KurrentDB", package: "swift-kurrentdb")
```

---

## Module 重新命名

| 舊名稱 (DDDKit) | 新名稱 (swift-ddd-kit) | 說明 |
|---|---|---|
| `ESDBSupport` | `KurrentSupport` | KurrentDB adapter 模組 |
| `JBEventBus` | `EventBus` | In-memory event bus 模組 |

如果你有直接 import 這些 module（而非透過 umbrella `DDDKit`），需要修改：

```diff
- import ESDBSupport
+ import KurrentSupport

- import JBEventBus
+ import EventBus
```

### Plugin 重新命名

```diff
- .plugin(name: "ProjectionModelGeneratorPlugin", targets: [...])
+ .plugin(name: "ModelGeneratorPlugin", targets: [...])
```

---

## Protocol / Type 重新命名

### `Projectable` → `EventStreamNaming`

```diff
- public protocol AggregateRoot: Projectable, Entity where ID == String
+ public protocol AggregateRoot: EventStreamNaming, Entity where ID == String
```

所有 conform `Projectable` 的地方改用 `EventStreamNaming`：

```diff
- extension MyProjector: Projectable { ... }
+ extension MyProjector: EventStreamNaming { ... }
```

### `Input` → `UseCaseInput`

```diff
- struct MyInput: Input { ... }
+ struct MyInput: UseCaseInput { ... }
```

### `Output` → `UseCaseOutput`

```diff
- struct MyOutput: Output { ... }
+ struct MyOutput: UseCaseOutput { ... }
```

### `Usecase` associated type 名稱

```diff
- public protocol Usecase<I, O> {
-     associatedtype I: Input
-     associatedtype O: Output
-     func execute(input: I) async throws -> O
+ public protocol Usecase<Input, Output> {
+     associatedtype Input: UseCaseInput
+     associatedtype Output: UseCaseOutput
+     func execute(input: Input) async throws -> Output
  }
```

如果你的實作有明確指定 associated type，需同步更新：

```diff
- typealias I = MyInput
- typealias O = MyOutput
+ typealias Input = MyInput
+ typealias Output = MyOutput
```

### `PresenterInput` → `CQRSProjectorInput`

```diff
- struct MyInput: PresenterInput { ... }
+ struct MyInput: CQRSProjectorInput { ... }
```

### `PresenterOutput` → `CQRSProjectorOutput`

```diff
- let output: PresenterOutput<MyReadModel> = ...
+ let output: CQRSProjectorOutput<MyReadModel> = ...
```

### `JBEventBus` → `EventBus`

```diff
- let bus = JBEventBus()
+ let bus = EventBus()
```

---

## Protocol 結構性變更

### `EventStorageCoordinator` 移除泛型參數

舊版本帶有 `ProjectableType` 泛型約束：

```diff
- public protocol EventStorageCoordinator<ProjectableType> {
-     associatedtype ProjectableType: Projectable
+ public protocol EventStorageCoordinator {
  }
```

實作端不再需要綁定特定的 Projectable 型別：

```diff
- class MyCoordinator: EventStorageCoordinator<MyAggregate> { ... }
+ class MyCoordinator: EventStorageCoordinator { ... }
```

### `EventSourcingRepository` 的 `StorageCoordinator` 約束放寬

```diff
- associatedtype StorageCoordinator: EventStorageCoordinator<AggregateRootType>
+ associatedtype StorageCoordinator: EventStorageCoordinator
```

### `KurrentStorageCoordinator` 泛型參數重新命名

```diff
- public class KurrentStorageCoordinator<ProjectableType: Projectable>: EventStorageCoordinator
+ public class KurrentStorageCoordinator<StreamNaming: EventStreamNaming>: EventStorageCoordinator
```

使用端：

```diff
- let coordinator = KurrentStorageCoordinator<MyAggregate>(client: client, eventMapper: mapper)
+ let coordinator = KurrentStorageCoordinator<MyAggregate>(client: client, eventMapper: mapper)
  // ↑ 用法不變，但如果你有 type annotation 提到 ProjectableType 需改為 StreamNaming
```

### `EventSourcingProjector` conformance 變更

```diff
- public protocol EventSourcingProjector: Projectable {
-     associatedtype Input: PresenterInput
-     associatedtype StorageCoordinator: EventStorageCoordinator<Self>
+ public protocol EventSourcingProjector: EventStreamNaming {
+     associatedtype Input: CQRSProjectorInput
+     associatedtype StorageCoordinator: EventStorageCoordinator
  }
```

回傳型別同步變更：

```diff
- func execute(input: Input) async throws -> PresenterOutput<ReadModelType>
+ func execute(input: Input) async throws -> CQRSProjectorOutput<ReadModelType>
```

---

## 新增功能

### `InMemoryEventStore`（EventSourcing 模組）

新增 thread-safe 的 in-memory 實作，適用於測試或不需要 KurrentDB 的場景（1.4 起由 `InMemoryStorageCoordinator` 更名為 `InMemoryEventStore`，行為依 EventStore 契約：revision 從 0 起算、`version: nil` 要求 stream 尚不存在、版本不符丟 `DDDError.commitConflict`、重送相同 event id 回傳原 revision、`purge` 後 `append` 丟 `streamPurged`）：

```swift
let coordinator = InMemoryEventStore<CustomMetadata>()
// conforms to EventStorageCoordinator
```

### `DDDKitUnitTests` 測試 target

新增不依賴 KurrentDB 的純 unit test target。

---

## 快速搜尋替換清單

以下是需要全域搜尋替換的項目（建議按順序執行）：

| 搜尋 | 替換 |
|---|---|
| `import ESDBSupport` | `import KurrentSupport` |
| `import JBEventBus` | `import EventBus` |
| `: Projectable` | `: EventStreamNaming` |
| `PresenterInput` | `CQRSProjectorInput` |
| `PresenterOutput` | `CQRSProjectorOutput` |
| `: Input ` (protocol conformance) | `: UseCaseInput ` |
| `: Output ` (protocol conformance) | `: UseCaseOutput ` |
| `JBEventBus()` | `EventBus()` |
| `JBEventBus` | `EventBus` |
| `EventStorageCoordinator<` | `EventStorageCoordinator` (移除泛型) |
| `typealias I =` | `typealias Input =` |
| `typealias O =` | `typealias Output =` |
| `package: "kurrentdb-swift"` | `package: "swift-kurrentdb"` |
| `KurrentDB-Swift.git` | `swift-kurrentdb.git` |
| `from: "1.10.0"` | `from: "2.0.0"` (KurrentDB) |
| `ProjectionModelGeneratorPlugin` | `ModelGeneratorPlugin` |

> **注意**：替換 `Input` / `Output` 時請小心避免誤改到 `CQRSProjectorInput` 等已替換的名稱，建議用正則或手動確認。


## 2026-05 — Ambient Context Replaces `external: [String:String]?`

`EventSourcingRepository.save(aggregateRoot:external:)` and
`EventStore.append(...,external:)` lose the `external` parameter. Metadata
now flows via `EventMetadataContext<M>` from Usecase entry. The protocol
also gains an `associatedtype Metadata: EventMetadata` on `EventStore`.

### Step 1 — Define your metadata schema (or use the bundled one)

The bundled `CustomMetadata` is a minimal schema carrying a single
`operatorId` field — if your existing code only passed a user id, this is the
drop-in replacement:

```swift
import KurrentSupport
// public struct CustomMetadata: EventMetadata { public let operatorId: String }
```

If you need more fields, define your own — the framework imposes no schema:

```swift
struct AuditMetadata: EventMetadata {
    let operatorId: String
    let tenantId: String
}
```

### Step 2 — Update Repository conformances

Add `Metadata` to your store's generic parameters:

```diff
- typealias Store = KurrentStorageCoordinator<OrderStreamNaming>
+ typealias Store = KurrentStorageCoordinator<OrderStreamNaming, CustomMetadata>
```

```diff
- let store: KurrentStorageCoordinator<OrderStreamNaming>
+ let store: KurrentStorageCoordinator<OrderStreamNaming, CustomMetadata>
```

Same for the in-memory store (named `InMemoryStorageCoordinator` before 1.4, now `InMemoryEventStore`):

```diff
- typealias Store = InMemoryStorageCoordinator
+ typealias Store = InMemoryEventStore<CustomMetadata>
```

### Step 3 — Update call sites

```diff
- try await repository.save(aggregateRoot: order, external: ["userId": userId])
+ try await EventMetadataContext<CustomMetadata>.withValue(
+     CustomMetadata(operatorId: userId)
+ ) {
+     try await repository.save(aggregateRoot: order)
+ }
```

For `delete`, same removal of `external:`:

```diff
- try await repository.delete(byId: id, external: nil)
+ try await repository.delete(byId: id)
```

The convenience overloads `save(aggregateRoot:userId:)` and `delete(byId:userId:)`
previously on `KurrentSupport`'s repository extension have been **removed**. Use
`EventMetadataContext<CustomMetadata>.withValue(...)` at the Usecase entry instead.

### Step 4 — Adopt ambient at Usecase entry (recommended)

The intended use is to set `EventMetadataContext` once at the Usecase entry,
so the rest of the body (and any nested repository / aggregate work) inherits
it via structured concurrency.

### Behavioural notes

- `Task.detached` does NOT inherit TaskLocal — capture and re-apply if needed.
- Multiple events in one `save` share one metadata payload.
- `Store.Metadata` and `event.Metadata` alignment is by convention; runtime
  mismatch yields `event.metadata = nil` on read, not a crash.
- Event-type resolution on read uses the KurrentDB-native `eventType` field
  (populated from `DomainEvent.eventType` at write time). The metadata payload
  carries no type discriminator — generated mappers switch on `eventData.eventType`.

## 1.4.0

### `ForwardingRule.translate` returns an array

```diff
- ForwardingRule(eventTypes: ["X"]) { record in try makeEvent(record) }      // PublishedLanguageEvent?
+ ForwardingRule(eventTypes: ["X"]) { record in [try makeEvent(record)] }    // [PublishedLanguageEvent]
```

Return `[]` where you returned `nil`. When one record yields several events, give each a
stable, distinct `eventId` (see `ForwardingRule`'s doc comment).

### Swift 6.1 minimum (1.4.0-beta.12)

`swift-tools-version` went from 6.0 to 6.1; a Swift 6.0 toolchain can no longer build the
package. Build with Swift 6.1 or later.

### New `EventStoreClient` requirements (1.4.0-beta.12)

Custom `EventStoreClient` conformances (wrappers, decorators, hand-written fakes) must implement
`ensurePersistentSubscription(stream:group:settings:)` and `deletePersistentSubscription(stream:group:)`.
Neither has a default, so a conformance without them no longer compiles. Forward them to the
wrapped client:

```swift
struct LoggingClient: EventStoreClient {
    let base: any EventStoreClient
    // ...other requirements...
+   func ensurePersistentSubscription(stream: String, group: String, settings: PersistentSubscriptionSettings) async throws {
+       try await base.ensurePersistentSubscription(stream: stream, group: group, settings: settings)
+   }
+   func deletePersistentSubscription(stream: String, group: String) async throws {
+       try await base.deletePersistentSubscription(stream: stream, group: group)
+   }
}
```

`tombstoneStream(name:)`, added after beta.14, does have a default but fails at run time; see "EventStore contract" §2 below.

### Behaviour changes (the compiler will not point these out)

- **Postgres snapshots default to `.monotonic` (1.4.0-beta.12).** The Postgres stores and
  `PostgresReadModelMigration` default to `SnapshotWriteMode.monotonic`: only a strictly newer
  revision is accepted, and rows go to `read_model_snapshots_monotonic`. Snapshots already in the
  old default table `read_model_snapshots` are not read, so they look missing. Either rebuild
  (`KurrentProjection.rebuild`) or pass `writeMode: .overwrite` to keep the old table and the old
  last-write-wins behaviour. Pass the same `tableName`/`writeMode` to the migration, the stores
  and `PostgresReadModelSnapshots`.
- **Subscription runners manage their own group (1.4.0-beta.12).** Both runners'
  `subscriptionSetup:` defaults to `.ensure(...)`: the group is created before subscribing; if it
  disappears it is recreated and `run()` throws `subscriptionGroupNotFound`, so call `run()` again
  (e.g. a restart loop with backoff). The credentials need permission to create persistent
  subscriptions; without it pass `.manual` to keep the old behaviour.
  `TransactionalSubscriptionRunner` now dispatches projectors one after another in registration
  order instead of concurrently. Generated projector `apply()` uses `default: continue`, so an
  unlisted event no longer stops the whole fold; regenerate.
- **`ContextForwarder` recreates a missing group (1.4.0-beta.11).** If the subscription group
  disappears while running, the forwarder recreates it with its original settings and throws, so
  the host resubscribes after a backoff. The new group starts from `subscriptionSettings.startFrom`
  (default `.end`); events written while the group was missing are not forwarded. No code change.

### EventStore contract (on main, not yet in a beta)

`EventStorageCoordinator` 的實作現在遵守同一份語意契約（見 `docs/superpowers/specs/2026-10-23-eventstore-contract-design.md`）。以下依影響程度列出。

#### 1. Production `purge` 改為 tombstone（永久）

`KurrentStorageCoordinator.purge` 現在呼叫 KurrentDB `tombstone(.any)`：

- Stream 永遠無法再寫入；之後對同一 id `append` 會丟 `DDDError.streamPurged`（code 502）。先 purge 再用同一個 id 重建 aggregate 的做法不再可行。
- 對從未寫過的 id 呼叫 `purge` 也會成功，並讓該 id 永久保留（之後無法寫入）。不要 purge 之後還會使用的 id。
- `EventSourcingRepository.purge` 不再先 `find`：未知的 id 不再丟 `aggregateNotFound`，已 soft-delete 的 aggregate 現在可以被 purge。

#### 2. 自訂 `EventStoreClient` wrapper / decorator 必須轉呼叫 `tombstoneStream(name:)`

`EventStoreClient` 新增 `tombstoneStream(name:)`。舊的 conformance 仍可編譯（協定擴充提供標為 deprecated 的預設實作，會有警告），但 `purge` 在執行時丟 `EventStoreClientError.tombstoneUnsupported`，stream 也不會被 purge。

```swift
struct LoggingClient: EventStoreClient {
    let base: any EventStoreClient
    // ...其他 requirement...
+   func tombstoneStream(name: String) async throws {
+       try await base.tombstoneStream(name: name)
+   }
}
```

#### 3. 版本衝突統一丟 `DDDError.commitConflict`

`KurrentStorageCoordinator` 與 `InMemoryEventStore` 在衝突時都丟 `DDDError.commitConflict`（code 501），取代 `EventStoreClientError.wrongExpectedRevision`、`KurrentError.wrongExpectedVersion`、`InMemoryStorageCoordinatorError.versionConflict`：

```diff
- } catch KurrentError.wrongExpectedVersion { ... }
+ } catch let error as DDDError where error.code == .commitConflict {
+     let conflict = error.commitConflict   // CommitConflict { id, expected, actual }
+     ...
+ }
```

#### 4. 新增的 enum case

`DDDError.Code` 新增 `commitConflict`(501)、`streamPurged`(502)、`storeUnavailable`(503)、`storeCorrupted`(504)；`EventStoreClientError` 新增 `tombstoneUnsupported`。沒有 `default` 的 exhaustive `switch` 需要補上這些 case。

#### 5. swift-kurrentdb 下限為 2.6.0

```diff
- .package(url: "https://github.com/gradyzhuo/swift-kurrentdb.git", from: "2.3.0")
+ .package(url: "https://github.com/gradyzhuo/swift-kurrentdb.git", from: "2.6.0")
```

#### 6. 其他行為變更

- 空陣列的 `append` 直接回傳 `nil`，不寫入也不呼叫 client。
- 對已存在的 stream 傳 `version: nil` 會衝突（`nil` 代表要求 stream 尚不存在）。
- `fetchEvents` 依 stream 回傳的順序，不再依 `occurred` 排序。
- `EventSourcingRepository.save` 在沒有新事件時不呼叫 store。
- `InMemoryStorageCoordinator` 更名為 `InMemoryEventStore`，revision 從 0 起算；詳見上方〈新增功能〉的 `InMemoryEventStore`。

#### 7. Generator 產出檔的 import 改變（source-breaking）

產出檔現在 import `Foundation`、`DDDCore`、`EventSourcing`，不再 import `KurrentSupport`／`KurrentDB`。若 `event.yaml` 以不再 import 的模組限定型別（例如 `KurrentSupport.CustomMetadata`），或使用只有 KurrentSupport／KurrentDB 提供的非限定型別，重新生成後會編譯失敗；KurrentSupport 的 typealias 無法補救，因為該模組沒被 import。二選一：

```diff
- actorMetadata: KurrentSupport.CustomMetadata
+ actorMetadata: EventSourcing.CustomMetadata   # 或非限定的 CustomMetadata
```

或在 `event-generator-config.yaml` 補上依賴：

```yaml
accessModifier: public
dependencies:
  - KurrentSupport
```

#### 8. 型別移到 EventSourcing

`RecordedEventLike`、`EventTypeMapper`、`CustomMetadata` 移到 `EventSourcing` 模組；`KurrentSupport` 保留同名 typealias，既有的 `import KurrentSupport` 程式碼不需修改。

#### 9. 新增 `PersistentEventStore`（`LocalEventStore`）

新的 `LocalEventStore` 模組提供 `PersistentEventStore`：給 iOS／macOS app 用的檔案式 `EventStore`，每個 stream 一個 JSON 檔、每次寫入整檔原子取代，不需要 server。這是新增功能，既有程式碼不需要修改。用法與限制（一個目錄只能開一個 instance、repository 與 projector 共用同一個 instance、目錄位置、沒有 fsync、`.defaultIsolation(MainActor.self)` 下要把 aggregate、projector 與 read model 宣告為 `nonisolated`）見 README 的〈Local Event Store (iOS and macOS apps)〉。

#### 10. `DDDError.StoreUnavailableReason`

`storeUnavailable`（503）帶一個 `DDDError.StoreUnavailableReason`，以 `error.storeUnavailableReason` 讀取：`invalidLocation`、`streamNameTooLong`、`io`、`occupied`、`closed`。`storeCorrupted`（504）以 `error.corruptedStream` 讀出無法讀取的 stream。目前只有 `PersistentEventStore` 丟這兩個 code。對 `StoreUnavailableReason` 寫沒有 `default` 的 `switch`，日後新增 case 時會編不過。

#### 11. iOS／Mac Catalyst 最低版本 18（source-breaking）

`Package.swift` 的 `platforms` 加上 `.iOS(.v18)`，這個值套用到本 package 的**每一個** product。以 iOS 或 Mac Catalyst 18 以下為目標建置任一 product 的專案會建置失敗（SwiftPM 回報該 product 要求 iOS 18.0），需把 deployment target 提高到 18。只建置 macOS 或 Linux 的專案不受影響（macOS 仍是 15+）。

#### 12. 新增三個 product（source-compatible）

`DDDCore`、`EventSourcing`、`LocalEventStore` 成為 library product，三者只依賴彼此、Foundation 與 swift-log，可建置於 iOS 18+。app 可以只依賴這三個，不必拉進 `DDDKit` umbrella 與 KurrentDB／Postgres 相依。既有的 `DDDKit` 等 product 不變。

#### 13. 超過 `Int64.max` 的預期 revision 改丟 `commitConflict`（behaviour change）

KurrentDB 無法接受大於 `Int64.max` 的預期 revision，以前 `KurrentStorageCoordinator.append` 會把它送出去，得到 server 回的 gRPC 內部錯誤。現在 `version` 大於 `UInt64(Int64.max)` 時不送出 append，改丟 `DDDError.commitConflict`，`actual` 為讀 stream 得到的尾端 revision（stream 不存在時為 `nil`）；若該 stream 已被 tombstone，則丟 `streamPurged`。`Int64.max` 本身照常送出。
