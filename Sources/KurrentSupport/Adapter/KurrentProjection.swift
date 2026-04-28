//
//  KurrentProjection.swift
//  KurrentSupport
//
//  Phase 1 — Persistent Subscription Runner.
//  See spec: docs/superpowers/specs/2026-04-28-kurrent-projection-runner-design.md
//

import Foundation
import KurrentDB

public enum KurrentProjection {

    public enum NackAction: Sendable {
        case retry
        case skip
        case park
        case stop
    }
}
