# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Build the package
swift build

# Run all tests (requires KurrentDB running on localhost)
swift test

# Run a specific test target
swift test --filter EventSourcingTests

# Run a specific test function
swift test --filter EventSourcingTests/testProjector

# Build a specific target
swift build --target DDDKit

# Run the code generator CLI
swift run generate event --input Sources/MyTarget/event.yaml --config Sources/MyTarget/event-generator-config.yaml
swift run generate projection --input Sources/MyTarget/projection-model.yaml
```

`DDDCoreTests` requires a local KurrentDB instance (connects to `localhost`). `EventSourcingTests` uses an in-memory `TestCoordinator` and can run without KurrentDB.

## Architecture Overview

DDDKit is a Domain-Driven Design + Event Sourcing framework for Server-Side Swift (Swift 6), targeting Ubuntu (Linux) and macOS 15+. It uses KurrentDB as the event store.

### Layer Structure

```
DDDKit (umbrella re-export)
├── DDDCore          — Core DDD protocols: Entity, DomainEvent, AggregateRoot, DomainEventBus
├── EventSourcing    — Abstract event sourcing patterns: EventStorageCoordinator, EventSourcingRepository, EventSourcingProjector, ReadModel, CQRSProjectorInput/Output
├── KurrentSupport   — KurrentDB adapter: KurrentStorageCoordinator, EventTypeMapper, DomainEventBus+KurrentDB
├── EventBus         — In-memory event bus (EventBus class)
├── MigrationUtility — Event schema migration framework
├── DomainEventGenerator — YAML→Swift code generation library
└── TestUtility      — Helpers for integration tests against KurrentDB
```

### Key Protocols

**`AggregateRoot`** (DDDCore) — Full event-sourced state machine. Requires:
- `DeletedEventType` associated type
- `when(happened:)` to mutate state from events
- `metadata: AggregateRootMetadata` — holds uncommitted events, soft-delete flag, and version
- `ensureInvariant()` — validation hook (default is no-op)
- Stream naming is defined directly on `AggregateRoot` via `categoryRule`/`category`/`getStreamName(id:)` extensions

**`DomainEvent`** (DDDCore) — Base event type. Must be `Codable + Identifiable<UUID>`. The `eventType` property defaults to the Swift type name.

**`EventStorageCoordinator`** (EventSourcing) — Storage abstraction with no generic constraint. Interface is purely `id: String`-based: `fetchEvents(byId:)`, `append(events:byId:version:external:)`, `purge(byId:)`. Non-KurrentDB backends implement this without any stream naming dependency.

**`EventSourcingRepository`** (EventSourcing) — Builds on coordinator: `find(byId:)`, `save(aggregateRoot:external:)`, `delete(byId:external:)`, `purge(byId:)`. Default implementations handle event replay and soft-delete logic.

**`KurrentStorageCoordinator<StreamNaming: EventStreamNaming, Metadata: EventMetadata>`** (KurrentSupport) — Concrete `EventStore` wrapping a KurrentDB client. Stream names come from `StreamNaming`. The typed `Metadata?` passed to `append` is JSON-encoded into KurrentDB's `customMetadata` field; nil metadata writes no bytes.

**`EventTypeMapper`** (KurrentSupport) — Converts a raw `RecordedEvent` from KurrentDB into a typed `DomainEvent`. Implementations switch on `eventData.eventType`.

**`EventSourcingProjector`** (EventSourcing) — CQRS read side. Requires `StorageCoordinator: EventStorageCoordinator`, `Input: CQRSProjectorInput`, and `ReadModelType: ReadModel`. The `execute(input:)` default fetches events and folds them into a `ReadModel` via `apply(readModel:events:)`.

**`ReadModel`** (EventSourcing) — `Codable` type with an `id` for read-optimized projections.

**`DomainEventBus`** (DDDCore/EventBus) — Publish events and subscribe by event type. `EventBus` is the in-memory implementation.

### Code Generation (Plugins)

Two build-tool plugins auto-generate Swift source at build time:

- **`DomainEventGeneratorPlugin`** — Reads `event.yaml` + `event-generator-config.yaml` in the target, invokes `generate event`, outputs `generated-event.swift`.
- **`ProjectionModelGeneratorPlugin`** — Reads `projection-model.yaml`, invokes `generate projection`.

The `generate` executable (`Sources/generate/`) is the shared CLI. `DomainEventGenerator` contains the YAML parsing and Swift code emission logic.

### Event Sourcing Flow

1. Define events conforming to `DomainEvent` (or generate from `event.yaml`)
2. Implement `AggregateRoot` with `when(happened:)` handlers
3. Implement `EventTypeMapper` to deserialize KurrentDB `RecordedEvent` back to typed structs
4. Implement `EventSourcingRepository` backed by `KurrentStorageCoordinator`
5. `repository.save(aggregateRoot:)` — appends uncommitted events from `metadata` to KurrentDB
6. `repository.find(byId:)` — replays all events from KurrentDB through `when(happened:)` to reconstruct state

### Event Metadata Pattern

Application metadata (audit info, request ids, tenant ids) flows via
`EventMetadataContext<M: EventMetadata>` — a generic TaskLocal carrier —
from Usecase entry to `EventStore.append` at the storage boundary.
`AggregateRoot` and `DomainEvent` schemas never see ambient metadata on the
write path; the generated mapper fills `event.metadata` on the read path so
ReadModel / Projector can consume it normally.

Key types:
- `EventMetadata` (`Sources/EventSourcing/EventMetadata.swift`) — marker
  protocol, Codable + Sendable. Framework imposes no schema fields.
- `EventMetadataContext<M>` (`Sources/EventSourcing/EventMetadataContext.swift`)
  — TaskLocal-backed, dispatched per `M` via a hidden ObjectIdentifier-keyed
  dict. Public API: `EventMetadataContext<M>.withValue(value) { ... }` /
  `EventMetadataContext<M>.current`. Internal storage uses a dict because Swift
  refuses `@TaskLocal` on generic-type static properties.
- `EventStore.Metadata` — store-level type binding. `KurrentStorageCoordinator`
  carries `Metadata: EventMetadata` as a second generic param.
- `CustomMetadata` (`KurrentSupport`) — minimal bundled schema with a single
  `operatorId: String` field; the default `Metadata` type generator output
  references (`typealias Metadata = CustomMetadata`). Apps typically replace it
  with their own `EventMetadata`-conforming struct.

`EventSourcingRepository.save` default impl reads
`EventMetadataContext<Store.Metadata>.current` and passes typed `metadata` to
`store.append`. Write-side `event.metadata` is ignored; read-side mapper
populates it from `record.customMetadata`.

**Gotcha (for users):** `EventMetadataContext.withValue` takes a `@Sendable`
closure. Wrappers that capture a non-`Sendable` aggregate from outer scope hit
a Swift 6 capture error — workaround is `@unchecked Sendable` on the aggregate
or restructuring to construct the aggregate inside the closure.

## TODO

- **`RestorableAggregateRoot`** — 支援刪除後還原的 aggregate 協定。設計：
  - 新增 `RestoredEvent` 協定（對稱 `DeletedEvent`），要求 `init(id:aggregateRootId:occurred:)`
  - 新增 `RestorableAggregateRoot: AggregateRoot`，帶有 `associatedtype RestoredEventType: RestoredEvent`
  - 覆寫 `apply(event:)` guard 為 `!metadata.deleted || event is RestoredEventType`
  - 提供 `markRestore()` 預設實作（對稱 `markDelete()`）
  - `AggregateRootMetadata` 新增 `restore()` 方法（將 `deleted` 設回 `false`）
  - 基礎 `AggregateRoot.apply` 維持嚴格 `guard !metadata.deleted`，不受影響

- **`EventSourcingRepository.find(hiddingDeleted: false)`** — 目前重建邏輯有 bug：`init?(events:)` 重播 `DeletedEvent` 後 `deleted = true`，若之後又呼叫 `markDelete()` 會拋錯。需修正 find 的還原流程，不應在重建後額外呼叫 `markDelete()`。

### Migration

`MigrationUtility` provides the `Migration` protocol for evolving event schemas. Accepts an old `EventTypeMapper` and an array of `MigrationHandler`s. Supports custom `createdHandler` for reconstructing aggregates from migrated event streams.
