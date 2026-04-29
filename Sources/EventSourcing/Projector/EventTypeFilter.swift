//
//  EventTypeFilter.swift
//  EventSourcing
//
//  EventTypeFilter — pre-filter routing for projection runners.
//  See spec: docs/superpowers/specs/2026-04-28-event-type-filter-design.md
//

/// A filter declaring which event types a projection (or arbitrary registration)
/// is interested in.
///
/// Pass an instance to `KurrentProjection.PersistentSubscriptionRunner.register(...)`
/// to short-circuit dispatch for unrelated event types — no `extractInput` call,
/// no storage fetch, no apply, no cursor advance.
///
/// Mirrors the `EventTypeMapper` pattern: protocol + concrete struct (often
/// generator-emitted) + DI parameter.
public protocol EventTypeFilter: Sendable {
    /// Returns `true` if the given event type should be processed by the
    /// associated projection; `false` to silently skip.
    func handles(eventType: String) -> Bool
}
