# Design: PostgresJSONReadModelStore

**Date:** 2026-04-03
**Status:** Approved

## Context

`ReadModelPersistence` 模組已提供抽象的 `ReadModelStore` 協定與 `InMemoryReadModelStore`。本 spec 描述新增的 `ReadModelPersistencePostgres` 模組，提供基於 PostgreSQL + JSONB 的具體實作。

## Goals

- 所有 `ReadModel` 類型共用單一 table，透過 `type` 欄位區分
- `ReadModel` 以 JSONB 存儲，利用 PostgreSQL 原生 JSON 查詢能力
- 錯誤統一包裝，保留原始 cause
- 不假設應用框架（不依賴 Vapor / Hummingbird lifecycle）

## Non-Goals

- 不提供 table migration helper（由應用層自行管理）
- 不提供 `QueryExecutor` 抽象層（`ReadModelStore` 已是 DIP 邊界）
- 不支援非 `String` ID（`Model.ID == String`）

## Table Schema

```sql
CREATE TABLE read_model_snapshots (
    id         TEXT        NOT NULL,
    type       TEXT        NOT NULL,
    data       JSONB       NOT NULL,
    revision   BIGINT      NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (id, type)
);
```

- 複合主鍵 `(id, type)` — 不同 ReadModel 類型可共用 id
- `type` = `String(describing: Model.self)`（Swift 型別名）
- `data` = JSONB，由 `JSONEncoder` 序列化
- `revision` = `BIGINT`，與 `UInt64` 用 `bitPattern` 互轉
- `updated_at` — 除錯用途

## Module Structure

```
ReadModelPersistence（既有，擴充）
└── ReadModelStoreError              ← 新增

ReadModelPersistencePostgres（新模組）
└── PostgresJSONReadModelStore<Model>
```

### `ReadModelStoreError`

```swift
public enum ReadModelStoreError: Error {
    case fetchFailed(id: String, cause: any Error)
    case saveFailed(id: String, cause: any Error)
    case deleteFailed(id: String, cause: any Error)
}
```

所有 store backend 共用，保留原始 DB error 作為 cause。

### `PostgresJSONReadModelStore<Model>`

```swift
public struct PostgresJSONReadModelStore<Model: ReadModel & Sendable>: ReadModelStore
    where Model.ID == String
{
    public init(
        client: PostgresClient,
        tableName: String = "read_model_snapshots"
    )
}
```

**泛型必要性：**
- `fetch` 裡 `JSONDecoder().decode(Model.self, from: data)` 需要目標型別
- `save(readModel: Model, ...)` 參數本身是 `Model`
- `init` 裡 `String(describing: Model.self)` 取得型別名稱作為 `type` 欄位值

**錯誤處理：** 每個方法的 `PostgresError` 包裝成對應的 `ReadModelStoreError`。

## Implementation

### fetch

```swift
public func fetch(byId id: String) async throws -> StoredReadModel<Model>? {
    do {
        let rows = try await client.query(
            "SELECT data, revision FROM \(unescaped: tableName) WHERE id = \(id) AND type = \(typeName)"
        )
        for try await (data, revision) in rows.decode((Data, Int64).self) {
            let model = try JSONDecoder().decode(Model.self, from: data)
            return StoredReadModel(readModel: model, revision: UInt64(bitPattern: revision))
        }
        return nil
    } catch {
        throw ReadModelStoreError.fetchFailed(id: id, cause: error)
    }
}
```

### save

```swift
public func save(readModel: Model, revision: UInt64) async throws {
    do {
        let data = try JSONEncoder().encode(readModel)
        let rev = Int64(bitPattern: revision)
        try await client.query("""
            INSERT INTO \(unescaped: tableName) (id, type, data, revision, updated_at)
            VALUES (\(readModel.id), \(typeName), \(data), \(rev), now())
            ON CONFLICT (id, type) DO UPDATE
                SET data = \(data), revision = \(rev), updated_at = now()
            """)
    } catch {
        throw ReadModelStoreError.saveFailed(id: readModel.id, cause: error)
    }
}
```

### delete

```swift
public func delete(byId id: String) async throws {
    do {
        try await client.query(
            "DELETE FROM \(unescaped: tableName) WHERE id = \(id) AND type = \(typeName)"
        )
    } catch {
        throw ReadModelStoreError.deleteFailed(id: id, cause: error)
    }
}
```

## Dependencies

```swift
// Package.swift
.package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0")

.target(
    name: "ReadModelPersistencePostgres",
    dependencies: [
        "ReadModelPersistence",
        .product(name: "PostgresNIO", package: "postgres-nio"),
    ])
```

## Usage

```swift
import ReadModelPersistencePostgres

// 應用啟動時，使用者自行建立 table（框架不介入）
// CREATE TABLE read_model_snapshots (...)

let store = PostgresJSONReadModelStore<OrderSummary>(client: postgresClient)

let projector = OrderProjector(
    coordinator: kurrentCoordinator,
    store: store
)

let result = try await projector.execute(input: .init(id: "order-123"))
```
