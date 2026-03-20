# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Build the package
swift build

# Run all tests (requires KurrentDB running on localhost)
swift test

# Run a specific test
swift test --filter DDDCoreTests/testRepositorySave

# Build a specific target
swift build --target DDDKit

# Run the code generator CLI
swift run generate event --input Sources/MyTarget/event.yaml --config Sources/MyTarget/event-generator-config.yaml
swift run generate projection --input Sources/MyTarget/projection-model.yaml
```

Tests require a local KurrentDB instance. The test suite connects to `localhost` and clears/recreates streams on each run.

## Architecture Overview

DDDKit is a Domain-Driven Design + Event Sourcing framework for Swift 6, targeting macOS 15+ and iOS 16+. It uses KurrentDB (formerly EventStoreDB) as the event store.

### Layer Structure

```
DDDKit (umbrella re-export)
├── DDDCore          — Core DDD protocols: Entity, Projectable, DomainEvent, AggregateRoot, ReadModel, Repository, DomainEventBus
├── EventSourcing    — Abstract event sourcing patterns: EventStorageCoordinator, EventSourcingRepository, EventSourcingProjector
├── ESDBSupport      — KurrentDB adapter: ESDBStorageCoordinator, EventTypeMapper, DomainEventBus+KurrentDB
├── JBEventBus       — In-memory event bus (for local event distribution)
├── MigrationUtility — Event schema migration framework
├── DomainEventGenerator — YAML→Swift code generation library
└── TestUtility      — Helpers for integration tests against KurrentDB
```

### Key Protocols

**`AggregateRoot`** (DDDCore) — Full event-sourced state machine. Requires defining:
- `CreatedEventType` and `DeletedEventType` associated types
- `when(event:)` handlers to mutate state from events
- `ensureInvariant()` for validation before saving
- `metadata: AggregateRootMetadata` — holds uncommitted events and soft-delete/version state

**`DomainEvent`** (DDDCore) — Base event type. Must be `Codable + Identifiable<UUID>`. The `eventType` property defaults to the Swift type name.

**`EventStorageCoordinator`** (EventSourcing) — Abstracts storage: `fetchEvents(byId:)`, `append(events:byId:version:external:)`, `purge(byId:)`.

**`EventSourcingRepository`** (EventSourcing) — Builds on coordinator with `find(byId:)`, `save(aggregateRoot:external:)`, `delete(byId:external:)`, `purge(byId:)`.

**`EventTypeMapper`** (ESDBSupport) — Converts a raw `RecordedEvent` from KurrentDB into a typed `DomainEvent`. Implementations use a switch on `eventData.eventType`.

**`ESDBStorageCoordinator<T>`** (ESDBSupport) — Concrete coordinator wrapping a KurrentDB client. Stream names use the pattern `{Projectable.category}-{id}`. Events are stored with `CustomMetadata` containing the Swift class name and optional external key-value pairs.

**`ReadModel`** (DDDCore) — Like `AggregateRoot` but for read-optimized projections. Uses `restore(event:)` instead of `apply(event:)`.

**`DomainEventBus`** (DDDCore/JBEventBus) — Publish events and subscribe by event type. `postAllEvent(fromAggregateRoot:)` drains the aggregate's uncommitted events.

### Code Generation (Plugins)

Two build-tool plugins auto-generate Swift source at build time:

- **`DomainEventGeneratorPlugin`** — Reads `event.yaml` + `event-generator-config.yaml` in the target, invokes `generate event`, outputs `generated-event.swift`.
- **`ProjectionModelGeneratorPlugin`** — Reads `projection-model.yaml`, invokes `generate projection`, outputs `generated-projection-model.swift`.

The `generate` executable (in `Sources/generate/`) is the shared CLI. `DomainEventGenerator` (library) contains the YAML parsing and Swift code emission logic.

### Event Sourcing Flow

1. Define events conforming to `DomainEvent` (or generate them from `event.yaml`)
2. Implement `AggregateRoot` with `when(event:)` handlers
3. Implement `EventTypeMapper` to deserialize KurrentDB events back to typed structs
4. Implement `EventSourcingRepository` backed by `ESDBStorageCoordinator`
5. Call `repository.save(aggregateRoot:)` — this appends uncommitted events from `metadata` to KurrentDB
6. Call `repository.find(byId:)` — this replays all events from KurrentDB through `when(event:)` to reconstruct state

### Migration

`MigrationUtility` provides the `Migration` protocol for evolving event schemas. Migrations accept an old `EventTypeMapper` and an array of `MigrationHandler`s, and can provide a custom `createdHandler` for reconstructing aggregates from migrated event streams.
