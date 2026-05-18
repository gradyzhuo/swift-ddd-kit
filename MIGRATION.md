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

### `InMemoryStorageCoordinator`（EventSourcing 模組）

新增 thread-safe 的 in-memory 實作，適用於測試或不需要 KurrentDB 的場景：

```swift
let coordinator = InMemoryStorageCoordinator()
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

If your existing code passed `["userId": "..."]`-style dicts, the simplest
migration is to keep using `CustomMetadata` (which already has `external`
and an `operatorId` convenience):

```swift
import KurrentSupport
// CustomMetadata: Codable, Sendable, EventMetadata — already conforms.
```

Or define your own:

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

Same for `InMemoryStorageCoordinator`:

```diff
- typealias Store = InMemoryStorageCoordinator
+ typealias Store = InMemoryStorageCoordinator<CustomMetadata>
```

### Step 3 — Update call sites

```diff
- try await repository.save(aggregateRoot: order, external: ["userId": userId])
+ try await EventMetadataContext<CustomMetadata>.withValue(
+     CustomMetadata(className: "Order", external: ["userId": userId])
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
- `EventMetadataContext<M>.withValue` takes a `@Sendable` closure. If you wrap
  it in a helper that captures a non-`Sendable` aggregate from outer scope, the
  capture will fail to compile. Either restructure to construct the aggregate
  inside the closure, or mark your aggregate `@unchecked Sendable`.
- `RecordedEvent.userId` (a KurrentSupport convenience accessor) only works for
  apps that use `CustomMetadata` as their `Metadata` schema. Apps using a custom
  schema get nil from `record.userId`.
