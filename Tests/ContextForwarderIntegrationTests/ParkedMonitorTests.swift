import Foundation
import KurrentDB
import PublishedLanguage
import Testing
@testable import ContextForwarder

/// Records parked-count callbacks; actor-isolated (no @unchecked Sendable).
actor ParkedRecorder {
    private(set) var counts: [Int64] = []
    func record(_ count: Int64) { counts.append(count) }
    var sawParked: Bool { counts.contains { $0 > 0 } }
}

/// Never publishes — this suite is about the failure path.
actor UnusedPublisher: PublishedLanguagePublisher {
    func publish(_ event: PublishedLanguageEvent) async throws {
        preconditionFailure("this suite's rule always fails before publishing")
    }
}

@Suite("Parked monitoring", .serialized, .enabled(if: IntegrationEnvironment.fullEnabled))
struct ParkedMonitorTests {

    @Test("a permanently-failing rule parks the record and the monitor reports it")
    func permanentFailureIsParkedAndReported() async throws {
        let kurrentURL = try #require(IntegrationEnvironment.kurrentURL)
        let settings: ClientSettings = try kurrentURL.parse()
        let client = KurrentDBClient(settings: settings)

        let suffix = UUID().uuidString.prefix(8).lowercased()
        let category = "ParkTest\(suffix)"
        let group = "parked-monitor-test-\(suffix)"
        let recorder = ParkedRecorder()

        var subscriptionSettings = ContextForwarder.SubscriptionSettings()
        subscriptionSettings.startFrom = .start        // the seed is appended first
        // Permanent errors park immediately — there's no retry loop for
        // maxRetryCount to bound. It's set low here only as a belt-and-braces
        // cap in case this failure were ever (mis)classified as transient.
        subscriptionSettings.maxRetryCount = 1
        var monitoring = ContextForwarder.MonitoringSettings()
        monitoring.parkedCheckInterval = .milliseconds(300)
        monitoring.onParkedDetected = { count in await recorder.record(count) }

        let forwarder = ContextForwarder(
            client: client,
            publisher: UnusedPublisher(),
            stream: "$ce-\(category)",
            groupName: group,
            subscriptionSettings: subscriptionSettings,
            monitoring: monitoring
        ).register(ForwardingRule(eventTypes: ["Unparseable"]) { record in
            // Body doesn't match — decodeBody throws .permanent.
            struct Expected: Decodable { let required: String }
            _ = try record.decodeBody(Expected.self)
            return nil
        })

        try await forwarder.ensureSubscription()
        struct Seed: Codable { let unexpected: String }
        try await client.streams(specified: "\(category)-one").append(events: [
            EventData(eventType: "Unparseable", model: Seed(unexpected: "shape"))
        ])

        let runner = Task { try? await forwarder.run() }
        defer { runner.cancel() }

        var sawParked = false
        for _ in 0..<60 {
            if await recorder.sawParked { sawParked = true; break }
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect(sawParked)

        runner.cancel()
        _ = try? await client.persistentSubscriptions(stream: "$ce-\(category)", group: group).delete()
        _ = try? await client.streams(specified: "\(category)-one").delete { $0.expectedRevision = .any }
    }
}
