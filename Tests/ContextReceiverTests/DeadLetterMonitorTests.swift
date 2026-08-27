import Logging
import Testing
@testable import ContextReceiver

@Suite("Dead letter monitor")
struct DeadLetterMonitorTests {
    private actor StubProbe: DeadLetterBacklogProbe {
        private var counts: [Int]
        private(set) var calls = 0
        init(counts: [Int]) { self.counts = counts }
        func backlogCount(topic: String) async throws -> Int {
            defer { calls += 1 }
            return counts.indices.contains(calls) ? counts[calls] : counts.last ?? 0
        }
    }

    private actor AlertSink {
        private(set) var alerts: [Int] = []
        func record(_ count: Int) { alerts.append(count) }
    }

    private var logger: Logger { Logger(label: "test") }

    @Test func alertsWhenBacklogCrossesThreshold() async throws {
        let probe = StubProbe(counts: [0, 7])
        let sink = AlertSink()
        let monitor = DeadLetterMonitor(
            probe: probe, topic: "t-DLQ", interval: .milliseconds(1),
            threshold: 5, maxChecks: 2, logger: logger,
            onAlert: { await sink.record($0) }
        )
        try await monitor.run()
        #expect(await sink.alerts == [7])
    }

    /// Pins the `>=` boundary itself: `alertsWhenBacklogCrossesThreshold` uses
    /// backlog 7 against threshold 5, which passes under `>` just as well as
    /// `>=`. At the default `threshold: 1`, a `>` regression would silently
    /// require a second dead-lettered message before alerting — exactly the
    /// silence this component exists to prevent.
    @Test func alertsWhenBacklogExactlyEqualsThreshold() async throws {
        let probe = StubProbe(counts: [1])
        let sink = AlertSink()
        let monitor = DeadLetterMonitor(
            probe: probe, topic: "t-DLQ", interval: .milliseconds(1),
            threshold: 1, maxChecks: 1, logger: logger,
            onAlert: { await sink.record($0) }
        )
        try await monitor.run()
        #expect(await sink.alerts == [1])
    }

    @Test func staysSilentBelowThreshold() async throws {
        let probe = StubProbe(counts: [0, 1])
        let sink = AlertSink()
        let monitor = DeadLetterMonitor(
            probe: probe, topic: "t-DLQ", interval: .milliseconds(1),
            threshold: 5, maxChecks: 2, logger: logger,
            onAlert: { await sink.record($0) }
        )
        try await monitor.run()
        #expect(await sink.alerts.isEmpty)
    }

    /// A probe failure must not kill the monitor — the DLQ is still filling.
    @Test func survivesProbeFailure() async throws {
        actor FailingProbe: DeadLetterBacklogProbe {
            private(set) var calls = 0
            func backlogCount(topic: String) async throws -> Int {
                calls += 1
                throw ReceiveError.adminProbeFailed("HTTP 503")
            }
        }
        let probe = FailingProbe()
        let monitor = DeadLetterMonitor(
            probe: probe, topic: "t-DLQ", interval: .milliseconds(1),
            threshold: 1, maxChecks: 3, logger: logger, onAlert: { _ in }
        )
        try await monitor.run()
        #expect(await probe.calls == 3)
    }
}
