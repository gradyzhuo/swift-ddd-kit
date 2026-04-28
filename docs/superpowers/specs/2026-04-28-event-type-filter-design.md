# Design: EventTypeFilter — pre-filter routing for PersistentSubscriptionRunner

**Date:** 2026-04-28
**Status:** Approved
**Builds on:** `docs/superpowers/specs/2026-04-28-kurrent-projection-runner-design.md` (Phase 1 — already merged via PR #3)

## Context

Phase 1 of `KurrentProjection.PersistentSubscriptionRunner` ships with a "dispatch all, filter inside projector" semantic:

- Every event delivered by the persistent subscription is dispatched to **every** registered projector
- Each projector's `extractInput` runs (returning `nil` to skip)
- Otherwise `StatefulEventSourcingProjector.execute(input:)` runs
- `execute` fetches events from the storage (via `EventTypeMapper`) and passes them to `projector.apply(readModel:events:)`
- The generated `apply` switches on event type — known events fire `when()`, unknown ones fall to `default: return`

The functional outcome is correct (each projection only acts on events it knows about), but **performance is wasteful**: every projector triggers a fetch round-trip for every event delivered, even events its projector never `when()`-handles.

For 3 projectors A (E1, E2), B (E1, E3), C (E4, E5) subscribed to a stream that delivers 5 event types, every event causes 3 fetches even though at most 2 projectors care about any given event.

Since `projection-model.yaml` already declares the events each projection consumes, the generator can produce a routing component that pre-filters at the runner level — eliminating the wasted fetches.

The user explicitly chose composition + DI (matching the existing `EventTypeMapper` pattern) over a `static var handledEventTypes` on the projector protocol.

## Goals

- Add an `EventTypeFilter` protocol, a peer to `EventTypeMapper`, that lets users (and the generator) declare which event types a registration cares about
- Have `ModelGeneratorPlugin` emit one concrete filter struct per `projection-model.yaml` model
- Update `PersistentSubscriptionRunner.register(...)` to accept an optional `EventTypeFilter` and short-circuit `extractInput` for unrelated events
- 100% backwards-compatible — existing call sites with no filter argument continue to work (no filter = no pre-filtering, current behavior preserved)
- Independently unit-testable filter implementations

## Non-Goals

- ❌ Don't add the filter to `EventSourcingProjector` as an associated type or static — explicitly rejected by the user
- ❌ Don't replace the projector's internal `apply` switch — keep it as the second line of defense (correctness even if filter is wrong / absent)
- ❌ Don't filter on richer info than `eventType: String` — e.g., metadata, payload, stream name. Future enhancement; not Phase 1 of this spec
- ❌ Don't auto-derive a default filter when the user doesn't pass one — `nil` means "no filter", explicitly chosen
- ❌ Don't make filter mandatory — backwards compat is hard goal

## Module Placement

`EventTypeFilter` lives in **`EventSourcing`** (not `KurrentSupport`). Rationale:

- The protocol takes a plain `String` (event type), not `RecordedEvent` — no KurrentDB-specific types
- It's a generic event-routing concept that any storage backend's runner could reuse
- `EventTypeMapper` is in `KurrentSupport` only because it deals with KurrentDB's `RecordedEvent` — that's storage-specific. `EventTypeFilter` isn't.

File: `Sources/EventSourcing/Projector/EventTypeFilter.swift`

## Generated Filter Placement

Generated filter structs live in their own file: **`generated-event-filter.swift`** — emitted by a new `EventFilterGenerator`, sibling to `EventMapperGenerator`'s output (`generated-event-mapper.swift`). One plugin output → one generated file. Cleaner separation; easier to disable filter generation in the future without touching mapper output.

## Public API

### 1. `EventTypeFilter` protocol

```swift
// Sources/EventSourcing/Projector/EventTypeFilter.swift

public protocol EventTypeFilter: Sendable {
    /// Returns `true` if events of the given type should be processed by the
    /// projection this filter is associated with; `false` to skip.
    ///
    /// Called by `KurrentProjection.PersistentSubscriptionRunner` (and any
    /// equivalent runner) for each incoming event before invoking
    /// `extractInput`. A `false` return causes the event to be silently
    /// skipped for the registered projection — no fetch, no apply, no
    /// cursor advance.
    func handles(eventType: String) -> Bool
}
```

### 2. Generated concrete filter (per projection model)

For each model in `projection-model.yaml`:

```yaml
OrderSummary:
  model: readModel
  events:
    - OrderCreated
    - OrderAmountUpdated
    - OrderCancelled
```

The generator emits:

```swift
internal struct OrderSummaryEventFilter: EventTypeFilter {
    internal init() {}

    internal func handles(eventType: String) -> Bool {
        switch eventType {
        case "OrderCreated", "OrderAmountUpdated", "OrderCancelled":
            return true
        default:
            return false
        }
    }
}
```

Naming convention: `{ModelName}EventFilter` — mirrors `{ModelName}EventMapper`.

### 3. Runner `register` overloads accept optional filter

Both overloads gain an optional `eventFilter:` parameter:

```swift
// High-level overload
@discardableResult
public func register<Projector, Store>(
    _ stateful: StatefulEventSourcingProjector<Projector, Store>,
    eventFilter: (any EventTypeFilter)? = nil,    // ← new
    extractInput: @Sendable @escaping (RecordedEvent) -> Projector.Input?
) -> Self
    where Store.Model == Projector.ReadModelType,
          Projector.Input: Sendable

// Low-level overload
@discardableResult
public func register<Input: Sendable>(
    eventFilter: (any EventTypeFilter)? = nil,    // ← new
    extractInput: @Sendable @escaping (RecordedEvent) -> Input?,
    execute: @Sendable @escaping (Input) async throws -> Void
) -> Self
```

`nil` (default) → no filter, all events pass through to `extractInput` (current behavior).

A non-nil filter → `eventType` is checked first; if `handles` returns `false`, the registration is skipped for this event without invoking `extractInput`, `execute`, or any storage round-trip.

### 4. Usage example

```swift
runner
    .register(summaryStateful,
              eventFilter: OrderSummaryEventFilter(),    // generated
              extractInput: { OrderSummaryInput(id: $0.streamIdentifier.name) })
    .register(timelineStateful,
              eventFilter: OrderTimelineEventFilter(),
              extractInput: { OrderTimelineInput(id: $0.streamIdentifier.name) })
    .register(unrelatedStateful,
              extractInput: { ... })   // no filter — accepts every event
```

## Implementation Sketch

Inside `register(_:eventFilter:extractInput:)` (high-level overload), delegate to the low-level one with the filter wrapped into the extractor:

```swift
@discardableResult
public func register<Projector, Store>(
    _ stateful: StatefulEventSourcingProjector<Projector, Store>,
    eventFilter: (any EventTypeFilter)? = nil,
    extractInput: @Sendable @escaping (RecordedEvent) -> Projector.Input?
) -> Self
    where Store.Model == Projector.ReadModelType,
          Projector.Input: Sendable
{
    register(eventFilter: eventFilter, extractInput: extractInput) { input in
        _ = try await stateful.execute(input: input)
    }
}
```

Inside the low-level overload, gate `extractInput` on the filter:

```swift
@discardableResult
public func register<Input: Sendable>(
    eventFilter: (any EventTypeFilter)? = nil,
    extractInput: @Sendable @escaping (RecordedEvent) -> Input?,
    execute: @Sendable @escaping (Input) async throws -> Void
) -> Self {
    let registration = Registration(dispatch: { record in
        if let filter = eventFilter, !filter.handles(eventType: record.eventType) {
            return    // pre-filter: skip this projection for this event
        }
        guard let input = extractInput(record) else { return }
        try await execute(input)
    })
    _registrations.withLock { $0.append(registration) }
    return self
}
```

Single call site for the filter check. No additional state stored.

## Backwards Compatibility

| Caller pattern | Phase 1 behavior | Phase 1 + filter behavior |
|---|---|---|
| `.register(stateful) { ... }` | Dispatch all events through extractInput | Same — `eventFilter` defaults to `nil` |
| `.register(extractInput:execute:)` | Dispatch all events | Same |
| `.register(stateful, eventFilter: F()) { ... }` | N/A | Pre-filter, only `handles == true` events reach extractInput |

Existing migrations of either runner overload's tests / sample app: no changes required.

## Generator Changes

`ModelGeneratorPlugin` already emits `generated-projection-model.swift` (protocols) and uses `EventMapperGenerator` for `generated-event-mapper.swift`. Add a parallel `EventFilterGenerator` and wire it into the same pipeline.

```swift
// Sources/DomainEventGenerator/Generator/EventFilter/EventFilterGenerator.swift
package struct EventFilterGenerator {
    let modelName: String
    let eventNames: [String]

    package init(modelName: String, eventNames: [String]) { ... }

    package func render(accessLevel: AccessLevel) -> [String] {
        // emit `internal struct {modelName}EventFilter: EventTypeFilter { ... }`
    }
}
```

Output target: `generated-event-filter.swift` (sibling to `generated-event-mapper.swift`).

The generator is invoked once per `projection-model.yaml` model, with the model name + the events array from yaml.

## Testing Strategy

1. **Unit tests for `EventTypeFilter`** in `EventSourcingTests` (or new `EventSourcingUnitTests`):
   - Default `nil` filter behavior (no filter)
   - Custom filter implementations work as expected
   - Edge cases (empty handled set returns false for everything)

2. **Unit tests for `EventFilterGenerator`** in `DomainEventGeneratorTests`:
   - Given a model + event list, the generated string contains the expected `case` clauses + struct boilerplate
   - Output matches snapshot for known input

3. **Unit tests for `register(eventFilter:)` runner integration** in `KurrentSupportUnitTests`:
   - Two registrations, one with filter that excludes an event type, one without
   - After dispatching events of varying types via the test-only registrationCount path, verify only the right set of registrations fired
   - This requires a way to verify dispatch behavior without real KurrentDB; previously we exposed `registrationCount` for chaining tests. We may need a similar test hook for "what got dispatched" — see Open Item

4. **Integration test in `KurrentSupportIntegrationTests`** — end-to-end:
   - 3 projectors, 3 distinct event types, custom filters; verify only the matched projectors saw events

5. **Sample update**: extend `KurrentProjectionDemo` (if revived from feature branch) to include a third projector with a custom filter, demonstrating the pattern. Or add this to the sample as a follow-up commit.

## Migration

No migration needed. Existing call sites continue to work. Users can opt into filtering by adding `eventFilter: SomeFilter()` to their `register` calls. Generator-emitted filters are additive — they appear in `generated-event-mapper.swift` (or new file) but don't replace existing types.

## Open Items (resolved)

1. **Output file** ✅ — new file `generated-event-filter.swift`, separate from event mapper output
2. **Test hook** ✅ — accepted. Detailed design during plan writing (likely a `_dispatch(eventType:)` test-only hook on the runner that synthesizes a minimal call site without needing real `RecordedEvent`)
3. **Sample integration** ✅ — revive `KurrentProjectionDemo` (currently on the unmerged local `feature/kurrent-projection-runner-phase1` branch's `a74b76c` commit) and update it to demonstrate the filter pattern. Cherry-pick the existing sample as the starting point; add a third projector with custom filter to showcase pre-filtering
4. **Naming** ✅ — `EventTypeFilter` confirmed

## Out of Scope (deferred)

- Filtering on richer event metadata (payload, stream name, custom metadata) — future enhancement; current `eventType: String` is sufficient for the yaml-generated case
- Auto-injecting the generator-emitted filter when user calls `register(_:extractInput:)` without specifying `eventFilter:` — explicitly opt-in keeps the API honest
- Filtering at the storage-fetch layer (skip events of unrelated types when fetching from the stream) — this would be a deeper optimization but couples filter to coordinator. Out of scope.
