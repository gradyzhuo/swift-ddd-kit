import AsyncHTTPClient
import Foundation
import Testing
@testable import ContextForwarder

@Suite("Pulsar REST publisher", .serialized, .enabled(if: IntegrationEnvironment.pulsarEnabled))
struct PulsarPublisherTests {

    @Test("ensureTopic is idempotent and publish lands messages")
    func publishLands() async throws {
        let base = try #require(IntegrationEnvironment.pulsarURL)
        let topic = "forwarder-test-\(UUID().uuidString.prefix(8).lowercased())"
        let publisher = PulsarRESTPublisher(
            httpClient: .shared,
            configuration: .init(baseURL: base, topic: topic))

        try await publisher.ensureTopic()
        try await publisher.ensureTopic()  // second call must tolerate 409

        let event = PublishedLanguageEvent(
            eventId: "evt-\(UUID().uuidString)",
            eventType: "ForwarderTest.v1",
            occurredAt: Date(),
            recipientIds: ["acc-1"],
            payload: ["k": "v"])
        try await publisher.publish(event)
        try await publisher.publish(event)  // retry-safe

        // Observed on Pulsar 4.0.2 standalone: REST-produced messages do not
        // increment stats.msgInCounter; internalStats.entriesAddedCounter
        // tracks them — see task report for transcripts.
        var statsRequest = HTTPClientRequest(url: "\(base)/admin/v2/persistent/public/default/\(topic)/internalStats")
        statsRequest.method = .GET
        let response = try await HTTPClient.shared.execute(statsRequest, timeout: .seconds(10))
        let body = try await response.body.collect(upTo: 1 << 16)
        let stats = try JSONSerialization.jsonObject(with: Data(body.readableBytesView)) as? [String: Any]
        let entriesAdded = (stats?["entriesAddedCounter"] as? Int) ?? 0
        #expect(entriesAdded >= 2)
    }
}
