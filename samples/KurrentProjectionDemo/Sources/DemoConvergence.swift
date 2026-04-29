//
//  DemoConvergence.swift
//  KurrentProjectionDemo — DEMO-ONLY helper
//
//  IMPORTANT: This file is artificial scaffolding for the demo. It does NOT
//  represent how a production system uses `KurrentProjection.PersistentSubscriptionRunner`.
//
//  ## Why this exists
//
//  In a real deployment the three roles live in three separate processes:
//
//      ┌──────────────┐    ┌──────────────────┐    ┌──────────────┐
//      │  Publisher   │───▶│     KurrentDB    │◀───│    Runner    │
//      │ (your app)   │    │  (event store)   │    │  (long-lived │
//      └──────────────┘    └──────────────────┘    │   service)   │
//                                                   └──────┬───────┘
//                                                          │ writes
//                                                          ▼
//                                                  ┌──────────────┐
//                                                  │   ReadModel  │
//                                                  │     store    │
//                                                  └──────▲───────┘
//                                                         │ reads
//                                                  ┌──────────────┐
//                                                  │  API handler │
//                                                  │   (queries)  │
//                                                  └──────────────┘
//
//  - The publisher appends events and forgets — it does not wait for projectors.
//  - The runner is a long-lived service (e.g. hosted in a `ServiceGroup`); it never
//    "exits when it's caught up" because there's no finish line.
//  - The API handler reads from the store on each query and accepts whatever
//    snapshot is currently there (eventually consistent).
//
//  This demo squashes ALL THREE roles into one `main.swift` so you can read it
//  end-to-end. To be able to print "final state" and exit cleanly, the demo
//  must artificially wait for the runner to catch up — that's what
//  `awaitConvergence(...)` does. **You would never write this in production code.**
//
//  ## What the helper does
//
//  Polls a user-supplied predicate every `pollInterval` until it returns true,
//  or the `timeout` fires (whichever comes first). Returns silently in either
//  case — the caller is expected to read the read model state after the call
//  and decide whether convergence happened.
//

import Foundation

/// DEMO-ONLY: poll until the supplied predicate returns true, or `timeout` elapses.
///
/// See file header for why this exists and why production code would not use it.
///
/// - Parameters:
///   - timeout: max seconds to wait before giving up.
///   - pollInterval: gap between predicate evaluations.
///   - isConverged: predicate that returns `true` once the demo's expected state
///     has been reached (typically: each projector's read model has the events
///     applied that the demo just published).
func awaitConvergence(
    timeout: TimeInterval,
    pollInterval: Duration = .milliseconds(200),
    until isConverged: @Sendable () async throws -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await isConverged() { return }
        try await Task.sleep(for: pollInterval)
    }
}
