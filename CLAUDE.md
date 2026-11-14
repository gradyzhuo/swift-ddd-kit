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

`DDDCoreTests` and `KurrentSupportIntegrationTests` require a local KurrentDB instance (connects to `localhost`). `EventSourcingTests` uses an in-memory `InMemoryEventStore` and can run without KurrentDB. `EventStoreContractTests` runs the shared `EventStore` contract (`EventStoreContract` target, internal, not a product) against every in-repo store — no KurrentDB needed. `KurrentSupportInMemoryTests` exercises `KurrentStorageCoordinator`/`KurrentProjection.PersistentSubscriptionRunner` end to end against `InMemoryEventStoreClient` (`KurrentSupportInMemory` target) — no KurrentDB needed either. `LocalEventStoreTests` covers `PersistentEventStore` on disk (temporary directories, no services); `EventStoreContractTests` also runs the contract against it. `EventStoreContractTests`, `LocalEventStoreTests` and `KurrentSupportUnitTests` (error mapping, the seam's defaults, runner setup and retry policy) need no server and run in CI's offline filter. `KurrentLiveContractTests` runs against a real KurrentDB: suite "Live KurrentDB" (`checkAll`, `checkHugeVersionConflicts`), `UnitOfWorkLiveTests` (`withUnitOfWork` end to end: atomic commit, conflicts, tombstones, metadata round-trip, soft-delete recreation, `$ce-` subscription) and `LiveEventStoreClientAppendAtomicallyTests` (the seam's `appendAtomically`). It needs a single-node insecure KurrentDB with standard projections running (`KURRENTDB_RUN_PROJECTIONS=All`, `KURRENTDB_START_STANDARD_PROJECTIONS=true`: the unit-of-work `$ce-` subscription test reads a stream only `$by_category` writes) and `KURRENTDB_POOL_URLS='["esdb://admin:changeit@localhost:2113?tls=false"]'`; without `KURRENTDB_POOL_URLS` it dials `TestUtility`'s local 3-node TLS cluster on ports 2111–2113 instead. It runs in CI's `kurrent-live-contract` job.

## Documentation Site

`.github/workflows/documentation.yml` builds DocC for every module and deploys it with the `docs/` landing page to GitHub Pages (source: GitHub Actions); it replaces the old `pages.yml`.
- No swift-docc-plugin: `scripts/emit-symbol-graphs.sh` compiles symbol graphs for every `Sources/*` module (minus an exclusion list of executables/demos/the re-export umbrella `DDDKit` — a new non-library target must be added there or the build fails), and `scripts/build-docs-site.py` converts each module, combines a version's modules with `docc merge`, and assembles the site
- Versioned: the latest patch of every minor from 1.0 (`scripts/doc-versions.py`; pre-releases skipped) at `/<major.minor>/`, main at `/main/`, the latest release also at the root; `docs/doc-versions.js` draws the version menu
- A module gets a richer landing page by adding a `Sources/<Module>/<Module>.docc` catalog — the workflow picks it up automatically
- `DOC_DEPENDENCY_PINS` in the workflow pins upstream releases that break the build (the package has no `Package.resolved`, so old releases resolve to new dependencies too); release symbol graphs are cached per commit + pins
- Runs on pushes to main and on `*.*.*` tags (the `github-pages` environment must allow both)
- Pages deploys each commit once: a tag on a commit main already deployed does not publish the new version (the deploy step still succeeds). After tagging main's HEAD, land another commit on main

## Architecture Overview

DDDKit is a Domain-Driven Design + Event Sourcing framework for Server-Side Swift (Swift 6.1+), targeting Ubuntu (Linux) and macOS 15+; `DDDCore`, `EventSourcing` and `LocalEventStore` also build for iOS 18+. It uses KurrentDB as the event store.

### Layer Structure

```
DDDKit (umbrella re-export)
├── DDDCore          — Core DDD protocols: Entity, DomainEvent, AggregateRoot, DomainEventBus
├── EventSourcing    — Abstract event sourcing patterns: EventStorageCoordinator, EventSourcingRepository, withUnitOfWork/UnitOfWork, EventSourcingProjector, ReadModel, CQRSProjectorInput/Output; also `RecordedEventLike`, `EventTypeMapper`, `CustomMetadata` (moved from KurrentSupport in 1.4; KurrentSupport keeps typealiases)
├── LocalEventStore  — PersistentEventStore: file-backed EventStore (one JSON file per stream, atomic writes, one open instance per directory)
├── KurrentSupport   — KurrentDB adapter: KurrentStorageCoordinator, DomainEventBus+KurrentDB (typealias for EventTypeMapper)
├── KurrentSupportInMemory — In-memory KurrentDB test double: InMemoryEventStoreClient (no live server needed)
├── EventBus         — In-memory event bus (EventBus class)
├── MigrationUtility — Event schema migration framework
├── DomainEventGenerator — YAML→Swift code generation library
├── TestUtility      — Helpers for integration tests against KurrentDB
└── ProjectorGeneratorFixture — Test-only fixture compiled with ModelGeneratorPlugin to exercise generated projector protocols (not documented)
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

**`EventStore` contract** (EventSourcing, spec `docs/superpowers/specs/2026-10-23-eventstore-contract-design.md`) — revisions start at 0; empty `append` is a no-op returning `nil`; `version: nil` requires no stream; mismatch throws `DDDError.commitConflict` (501, `error.commitConflict`); resending the same event ids returns the original revision; `purge` is permanent for any id (`append` then throws `streamPurged`, 502). Events come back in stream order. `InMemoryEventStore` (renamed from `InMemoryStorageCoordinator`), `KurrentStorageCoordinator` and `PersistentEventStore` follow it; `EventStoreContract.checkAll` checks a store against it. `EventStoreContract.checkHugeVersionConflicts` is a separate check (not in `checkAll`); it passes on real KurrentDB in `KurrentLiveContractTests`, because `KurrentStorageCoordinator` turns an expected revision above `Int64.max` into `commitConflict` without sending the append (KurrentDB cannot take such a revision; it only reads the stream to report the actual revision, and a purged stream still throws `streamPurged`). Outside a unit of work `EventSourcingRepository.save` returns early without calling the store when the aggregate has no new events (inside one it first refuses a non-participating store); `purge` calls `store.purge` directly (no `aggregateNotFound` for unknown ids). swift-kurrentdb floor is 3.0.0 (lazy reads; its own `CustomMetadata` type makes a bare `CustomMetadata` ambiguous in a file that also imports `KurrentDB`: write `EventSourcing.CustomMetadata` there).

**`withUnitOfWork` / `UnitOfWork`** (EventSourcing, spec `docs/superpowers/specs/2026-11-01-unit-of-work-design.md`) — `withUnitOfWork { work in … }` (`@discardableResult`, throws) collects the writes participating stores make in the block (TaskLocal scope, `UnitOfWork.current`) and commits them once the block returns; a block that throws (`CancellationError` included) commits nothing and runs no hook. No nesting: inside a scope it throws `operationNotAllow` and leaves the outer scope alone. The scope closes the moment the block returns or throws: `withBackend(_:identity:make:_:)`, `fail(_:)` and `onCommitted(_:)` then throw `operationNotAllow` (`already ended`), so a `Task {}` escaped from the block cannot save after it (`current` still points at the closed scope there, never `nil`), nor open its own `withUnitOfWork` (refused before and after the block ends; the reason says `already ended` once it has). `Task.detached` and code outside the block's task tree (NIO callbacks, `DispatchQueue` blocks) see `current == nil`, so a `save` there writes directly and stays written when the block throws (pinned by `detachedTaskSaveInsideBlockWritesDirectly`). Commit and hooks run outside the TaskLocal: hooks see `UnitOfWork.current == nil`, so a `save` inside a hook writes directly, outside the atomic commit. `work.fail(error)`, and any error from the store calls (or the participant check) of `EventSourcingRepository`'s default `find`/`save`/`delete`/`purge` even when caught, make the end throw `operationNotAllow(operation: "commit", reason: "unit of work failed")` with the first cause in `userInfos["cause"]`; `aggregateNotFound` and `markDelete` errors do not. `onCommitted` hooks run in order after a successful commit (a scope without a backend counts) and before `withUnitOfWork` returns; a throwing hook stops the rest, the commit stands. One `UnitOfWorkBackend` per scope (`make` and the staging `body` of `withBackend` run under the scope's lock, the one `close()` takes, so a stage from an escaped Task either lands before the close or throws; neither may re-enter); another type or identity throws `operationNotAllow`. Inside a scope the default `save` and `purge` refuse a store that is not a `UnitOfWorkParticipant` (`InMemoryEventStore`, `PersistentEventStore`) with `operationNotAllow`, `save` even with no new events; `find` is never gated; a direct `store.append`/`store.purge` on such a store still writes/purges at once. `KurrentStorageCoordinator` participates: `append` stages into `KurrentUnitOfWorkBackend` (package) keyed by `client.identity`, i.e. the same `KurrentDBClient` instance, not the same cluster, and returns the predicted tail (`.noStream` → count − 1, `.at(n)` → n + count); a second stage of one stream must expect that tail or throws `commitConflict`; each save first encodes every payload (an unencodable one throws its own `EncodingError`, nothing staged), then checks `EventRecord(eventData:)` can carry the metadata (not a JSON object → `operationNotAllow`; NaN/infinity already throw `EncodingError` from the coordinator's `JSONEncoder`, in or out of a scope; integers a Double cannot hold exactly — beyond ±2^53, over-64-bit ones such as a large `Decimal` included — are rounded without an error on the multi-stream path; the server adds `$schema.*` keys on read, on a commit of two or more streams also to an event saved with nil metadata; `LiveEventStoreClient` reads metadata whose keys are exactly `$schema.name`/`$schema.format` as empty (byte pre-check before parsing; `MigrationUtility` and direct `KurrentDBClient` reads still see them; `{}` metadata reads back nil after a multi-stream commit) (readStream and persistent deliveries, `withoutServerOnlyMetadata`), so nil metadata reads back empty on every path; `ForwardedRecord.normalizedMetadata` does the same for the forwarder; user keys starting with `$` survive AppendRecords); `fetchEvents` appends the staged events after the server's and throws `commitConflict` (expected = first staged revision − 1, nil for 0; actual = server tail; fails the scope) when the server's last record read is at or past the first staged revision, i.e. a save expected a revision the stream has since passed (a stream ending short of the expectation is left to the commit; `afterRevision` windows see only records after it); otherwise reads never create, pin or fail on the backend (a read through a client of another identity is allowed but sees only the server's events, so a usecase that reads an earlier save in the block needs the same `KurrentDBClient` instance); `purge` throws `operationNotAllow`. Commit: no batch → nothing; one → the v1 single-stream `append` (same errors and resend handling as outside a scope); two or more → `EventStoreClient.appendAtomically` (v2 `AppendRecords`, KurrentDB 26.1+; `unsupportedFeature` → `operationNotAllow`). `consistencyViolations` → `commitConflict(conflicts:)` (`error.commitConflicts`, batch order), a tombstoned stream → `streamPurged` (wins over conflicts); after those nothing was written, after any other commit error the writes may have landed (read before re-running the block). A returned revision that differs from the prediction (a soft-deleted stream recreated continues from the old tail + 1) is logged, not thrown; re-find aggregates after a block instead of reusing its instances. Projections run on the subscription runners, never synchronously inside a scope (reads there through the same client instance see staged events).

**`KurrentStorageCoordinator<StreamNaming: EventStreamNaming, Metadata: EventMetadata>`** (KurrentSupport) — Concrete `EventStore` wrapping an `any EventStoreClient` (not `KurrentDBClient` directly — see below). Stream names come from `StreamNaming`. The typed `Metadata?` passed to `append` is JSON-encoded into KurrentDB's `customMetadata` field; nil metadata writes no bytes.

**`PersistentEventStore<StreamNaming, Metadata>`** (LocalEventStore) — `EventStore` backed by a directory: `<hex of stream name>.json` per stream, whole file replaced with `Data.write(.atomic)` on every append, `purge` rewrites it as `purged: true` with no records (the payload leaves the file; also clears a corrupted stream, and the id stays unwritable). `open(directory:eventMapper:)` takes a `flock` on `<directory>/.lock` (second open → `storeUnavailable(.occupied)`), `close()` releases it. Share one instance between the repository and the projectors (on the Kurrent path each projector builds its own coordinator; here a second `open` of the directory fails). Not durable across power loss (no fsync). Errors: `storeUnavailable` (503, `error.storeUnavailableReason`) and `storeCorrupted` (504, `error.corruptedStream`).

**`EventTypeMapper`** (EventSourcing; KurrentSupport keeps a typealias) — Converts an `any RecordedEventLike` (decoupled from KurrentDB's concrete `RecordedEvent`) into a typed `DomainEvent`. Implementations switch on `eventData.eventType`.

**`EventStoreClient`** (KurrentSupport) — Narrow seam covering exactly the KurrentDB operations `KurrentStorageCoordinator`/`KurrentProjection` call: append/read/delete on a named stream, and subscribe/ack/nack on a persistent subscription. `RecordedEvent`/`ReadEvent`/`Streams`/`PersistentSubscriptions` (swift-kurrentdb) can't be constructed or conformed to from outside that package (no public initializers, gRPC-hardwired), so the seam is expressed in terms of `EventData` (already public) plus its own `RecordedEventLike`/`SubscriptionDelivery` DTOs. `LiveEventStoreClient` (KurrentSupport) is the production conformance, wrapping a real `KurrentDBClient`; `InMemoryEventStoreClient` (`KurrentSupportInMemory` target) needs no server at all (it mirrors KurrentDB 26.1's soft delete — a deleted stream reads as not found, keeps its tail for `.at(_:)` checks and is recreated from tail + 1 — and leaves a stream name without a `-` out of every `$ce-` category) — pass it to `KurrentStorageCoordinator`/`KurrentProjection.PersistentSubscriptionRunner`'s `client:` parameter in unit tests. Both runners and `KurrentStorageCoordinator` also keep a `client: KurrentDBClient` convenience initializer that wraps `LiveEventStoreClient` internally, so existing production call sites are unaffected. `tombstoneStream(name:)` (1.4) has a default that throws `tombstoneUnsupported`; `KurrentStorageCoordinator.purge` uses it, so wrappers must forward it. 1.5 adds `identity` (no default, by design: `LiveEventStoreClient` reports its `KurrentDBClient`'s `ObjectIdentifier`, `InMemoryEventStoreClient` its own) and `appendAtomically(_:)` (deprecated default throws `atomicAppendUnsupported`; `StreamBatch`/`StreamBatchResult`/`StreamConflict`, errors `consistencyViolations`/`resourceDeleted`); wrappers must forward both.

> **Breaking change (this repo and downstream apps):** `EventTypeMapper.mapping(eventData:)` and `KurrentProjection`'s `register(extractInput:...)` closures now take `any RecordedEventLike` instead of the concrete `RecordedEvent`. Call sites that only `switch eventData.eventType` / call `.decode(to:)` are source-compatible after updating the parameter type; code that read `RecordedEvent.streamIdentifier.name` should use the new `RecordedEventLike.streamName` property instead.

**`EventSourcingProjector`** (EventSourcing) — CQRS read side. Requires `StorageCoordinator: EventStorageCoordinator`, `Input: CQRSProjectorInput`, and `ReadModelType: ReadModel`. The `execute(input:)` default fetches events and folds them into a `ReadModel` via `apply(readModel:events:)`.

**`ReadModel`** (EventSourcing) — `Codable` type with an `id` for read-optimized projections.

**`SnapshotWriteMode`** (ReadModelPersistencePostgres) — `.monotonic` (default; only a strictly newer revision replaces a row, older/equal writes are skipped with a debug log, table `<base>_monotonic`) or `.overwrite` (last write wins, table `<base>`; pre-existing behaviour; for a single consumer with in-order delivery or an existing `read_model_snapshots` table). Pass the same `tableName`/`writeMode` to `PostgresReadModelMigration`, the stores and `PostgresReadModelSnapshots`.

**`ReadModelSnapshotPurging`** (ReadModelPersistence) — Backend capability to drop all snapshots of given `readModelTypeName`s; implemented by `PostgresReadModelSnapshots` and `InMemoryReadModelStore`.

**`ReadModel.readModelTypeName`** (EventSourcing) — Stored `type` key of a snapshot; defaults to `String(describing: Self.self)`. Override it for a name that survives Swift renames.

**`KurrentProjection.SubscriptionSetup`** (KurrentSupport) — Runner option: `.ensure(PersistentSubscriptionSettings)` (default; creates the group, recreates it and throws `subscriptionGroupNotFound` if it disappears) or `.manual`.

**`KurrentProjection.rebuild`** (KurrentSupport) — Deletes the group, purges the listed read models' snapshots via `ReadModelSnapshotPurging`, recreates the group from the start. Stop consumers first; every step is idempotent.

**`KurrentProjection.CommittedProjection` / `onCommitted(_:)`** (KurrentSupport) — Opt-in after-commit hooks on both runners. Queued after a delivery's commit (transactional) or successful saves (persistent), before the ack; never on rollback/failure/filtered/nil-input. Run on one background task per runner instance, shared across `run()` restarts (in order, never overlapping, off the subscription loop — a slow hook never delays the next delivery; unbounded queue; no ordering across instances). `writtenReadModels` = saves issued that returned without error (a `.monotonic` store may have skipped it because an equal-or-newer row is durable). Fires only in the handling process.

**`DomainEventBus`** (DDDCore/EventBus) — Publish events and subscribe by event type. `EventBus` is the in-memory implementation.

### Code Generation (Plugins)

Two build-tool plugins auto-generate Swift source at build time:

- **`DomainEventGeneratorPlugin`** — Reads `event.yaml` + `event-generator-config.yaml` in the target, invokes `generate event`, outputs `generated-event.swift`.
- **`ProjectionModelGeneratorPlugin`** — Reads `projection-model.yaml`, invokes `generate projection`.

The `generate` executable (`Sources/generate/`) is the shared CLI. `DomainEventGenerator` contains the YAML parsing and Swift code emission logic.

### Event Sourcing Flow

1. Define events conforming to `DomainEvent` (or generate from `event.yaml`)
2. Implement `AggregateRoot` with `when(happened:)` handlers
3. Implement `EventTypeMapper` to map each stored record (`any RecordedEventLike`) back to a typed event (or generate it from `event.yaml`)
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
