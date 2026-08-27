import Foundation
import Testing
@testable import ContextForwarder

/// Covers `ForwardingDisposition(forAnyOf:)` — the precedence used when
/// several rules match one record and some of them fail. A permanently
/// failing rule must never strand a sibling rule that could still translate
/// the same record, and since parked messages are never redelivered, this
/// decision is the record's only chance to get it right.
@Suite("Multi-rule disposition precedence")
struct MultiRuleDispositionTests {

    struct Transient: Error {}

    @Test("no failures acks: nil disposition")
    func noFailuresIsNil() {
        #expect(ForwardingDisposition(forAnyOf: []) == nil)
    }

    @Test("a single permanent failure parks")
    func singlePermanentParks() {
        #expect(ForwardingDisposition(forAnyOf: [ForwardingError.permanent(reason: "bad payload")]) == .park)
    }

    @Test("a single transient failure retries")
    func singleTransientRetries() {
        #expect(ForwardingDisposition(forAnyOf: [Transient()]) == .retry)
    }

    @Test("permanent + transient retries — the transient rule gets its only path to success")
    func permanentAndTransientRetries() {
        let failures: [any Error] = [ForwardingError.permanent(reason: "bad payload"), Transient()]
        #expect(ForwardingDisposition(forAnyOf: failures) == .retry)
    }

    @Test("permanent + permanent parks")
    func permanentAndPermanentParks() {
        let failures: [any Error] = [
            ForwardingError.permanent(reason: "bad payload"),
            ForwardingError.permanent(reason: "missing field"),
        ]
        #expect(ForwardingDisposition(forAnyOf: failures) == .park)
    }
}
