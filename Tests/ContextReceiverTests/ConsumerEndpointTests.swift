import Testing
@testable import ContextReceiver

@Suite("Consumer endpoint URL")
struct ConsumerEndpointTests {
    private func endpoint(_ settings: ConsumerEndpoint.Settings = .init()) -> ConsumerEndpoint {
        ConsumerEndpoint(
            baseURL: "ws://pulsar.internal:8080",
            tenant: "public", namespace: "default",
            topic: "opportunity-published-language",
            subscription: "notification-center",
            settings: settings
        )
    }

    @Test func buildsConsumerPath() {
        #expect(endpoint().url.hasPrefix(
            "ws://pulsar.internal:8080/ws/v2/consumer/persistent/public/default/opportunity-published-language/notification-center?"
        ))
    }

    /// Pull mode is mandatory: the runner's permit accounting depends on it.
    @Test func alwaysEnablesPullMode() {
        #expect(endpoint().url.contains("pullMode=true"))
    }

    @Test func defaultsToKeySharedForPerKeyOrdering() {
        #expect(endpoint().url.contains("subscriptionType=Key_Shared"))
    }

    @Test func includesOptionalSettingsOnlyWhenSet() {
        var settings = ConsumerEndpoint.Settings()
        settings.maxRedeliverCount = 5
        settings.deadLetterTopic = "persistent://public/default/notification-dlq"
        let url = endpoint(settings).url
        #expect(url.contains("maxRedeliverCount=5"))
        #expect(url.contains("deadLetterTopic=persistent%3A%2F%2Fpublic%2Fdefault%2Fnotification-dlq"))
        #expect(!url.contains("consumerName"))
        #expect(!url.contains("negativeAckRedeliveryDelay"))
    }

    // Auth-header coverage lives in
    // Tests/ContextReceiverWebSocketTests/WebSocketMessageSourceAuthTests.swift:
    // `ConsumerEndpoint.Settings` has no token/auth field at all, so a test
    // here asserting the URL never contains "token=" would pass no matter
    // what happened to auth handling — it can't fail, so it can't detect
    // anything. The real auth path (bearer token -> `Authorization` header,
    // never the query string) only exists on `WebSocketClientConfiguration`,
    // which is Linux-only.

    @Test func trimsTrailingSlashOnBaseURL() {
        let e = ConsumerEndpoint(
            baseURL: "ws://pulsar.internal:8080/",
            tenant: "public", namespace: "default", topic: "t", subscription: "s"
        )
        #expect(e.url.contains("://pulsar.internal:8080/ws/v2/"))
        #expect(!e.url.contains("8080//ws"))
    }
}
