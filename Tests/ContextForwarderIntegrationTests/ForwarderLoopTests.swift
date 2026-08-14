import AsyncHTTPClient
import Foundation
import KurrentDB
import PublishedLanguage
import Testing
@testable import ContextForwarder

/// In-memory recording publisher — actor-isolated (no @unchecked Sendable).
actor RecordingPublisher: PublishedLanguagePublisher {
    private(set) var published: [PublishedLanguageEvent] = []

    func publish(_ event: PublishedLanguageEvent) async throws {
        published.append(event)
    }
}

@Suite("Forwarder loop", .serialized, .enabled(if: IntegrationEnvironment.fullEnabled))
struct ForwarderLoopTests {

    private struct TestBody: Codable {
        let collaboratorId: String
        let role: String
        let occurred: Date
    }

    @Test("translates and publishes a matching event, then acks (live delivery)")
    func forwardsEndToEnd() async throws {
        let kurrentURL = try #require(IntegrationEnvironment.kurrentURL)
        let settings: ClientSettings = try kurrentURL.parse()
        let client = KurrentDBClient(settings: settings)

        let suffix = UUID().uuidString.prefix(8).lowercased()
        let category = "FwdTest\(suffix)"
        let streamName = "\(category)-case1"
        let group = "forwarder-loop-test-\(suffix)"

        let recorder = RecordingPublisher()
        let forwarder = ContextForwarder(
            client: client,
            publisher: recorder,
            stream: "$ce-\(category)",
            groupName: group
        ).register(ForwardingRule(eventTypes: ["CollaboratorAdded"]) { record in
            let decoded = try record.decodeBody(TestBody.self)
            return PublishedLanguageEvent(
                eventId: record.eventId,
                eventType: "OpportunityCollaboratorAdded.v1",
                occurredAt: try record.decodeOccurred(),
                recipientIds: [decoded.collaboratorId],
                payload: ["role": decoded.role])
        })

        // ensureSubscription() creates the group at its default cursor (.end)
        // BEFORE any event is seeded. If we seeded first, the event would
        // land behind the cursor at group-creation time and never be
        // delivered — a real race with the (now explicit) .end default.
        // Creating the group first guarantees the event we append next is
        // "live" relative to the subscription's start point.
        try await forwarder.ensureSubscription()

        // Seed one matching event (raw append via the streams API; model-encoding
        // EventData initializer — see swift-kurrentdb's EventData.swift).
        try await client.streams(specified: streamName).append(events: [
            EventData(eventType: "CollaboratorAdded", model: TestBody(collaboratorId: "acc-1", role: "editor", occurred: Date()))
        ])

        let runner = Task { try await forwarder.run() }
        defer { runner.cancel() }

        var events: [PublishedLanguageEvent] = []
        for _ in 0..<50 {
            events = await recorder.published
            if !events.isEmpty { break }
            try await Task.sleep(for: .milliseconds(200))
        }

        #expect(events.count == 1)
        #expect(events.first?.eventType == "OpportunityCollaboratorAdded.v1")
        #expect(events.first?.recipientIds == ["acc-1"])
        #expect(events.first?.payload["role"] == "editor")

        // cleanup
        runner.cancel()
        _ = try? await client.persistentSubscriptions(stream: "$ce-\(category)", group: group).delete()
        _ = try? await client.streams(specified: streamName).delete { $0.expectedRevision = .any }
    }
}
