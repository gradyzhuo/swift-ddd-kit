import Foundation

/// Builds the Pulsar WebSocket consumer URL. Lives in the portable target so
/// it can be unit-tested on any platform.
public struct ConsumerEndpoint: Sendable {
    public struct Settings: Sendable {
        /// Key_Shared gives per-key ordering plus multi-consumer scale-out.
        public var subscriptionType: String = "Key_Shared"
        public var consumerName: String?
        public var maxRedeliverCount: Int?
        public var deadLetterTopic: String?
        public var negativeAckRedeliveryDelayMillis: Int?
        public var receiverQueueSize: Int?
        public init() {}
    }

    private let baseURL: String
    private let tenant: String
    private let namespace: String
    private let topic: String
    private let subscription: String
    private let settings: Settings

    public init(
        baseURL: String, tenant: String, namespace: String,
        topic: String, subscription: String, settings: Settings = .init()
    ) {
        self.baseURL = baseURL
        self.tenant = tenant
        self.namespace = namespace
        self.topic = topic
        self.subscription = subscription
        self.settings = settings
    }

    /// Whether a dead-letter policy is configured. Pulsar's WebSocket API has
    /// no direct "send to DLQ now" command — `maxRedeliverCount` plus
    /// `deadLetterTopic` are what make a negative acknowledgement eventually
    /// park a message instead of looping it forever. The transport uses this
    /// to warn when a message deliberately routed to dead letter has no
    /// policy to actually get it there.
    public var hasDeadLetterPolicy: Bool {
        settings.maxRedeliverCount != nil || settings.deadLetterTopic != nil
    }

    public var url: String {
        let root = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let path = "\(root)/ws/v2/consumer/persistent/\(tenant)/\(namespace)/\(topic)/\(subscription)"

        var items = [
            URLQueryItem(name: "subscriptionType", value: settings.subscriptionType),
            // Not configurable: the runner grants permits explicitly.
            URLQueryItem(name: "pullMode", value: "true"),
        ]
        if let name = settings.consumerName {
            items.append(URLQueryItem(name: "consumerName", value: name))
        }
        if let count = settings.maxRedeliverCount {
            items.append(URLQueryItem(name: "maxRedeliverCount", value: "\(count)"))
        }
        if let dlq = settings.deadLetterTopic {
            items.append(URLQueryItem(name: "deadLetterTopic", value: dlq))
        }
        if let delay = settings.negativeAckRedeliveryDelayMillis {
            items.append(URLQueryItem(name: "negativeAckRedeliveryDelay", value: "\(delay)"))
        }
        if let size = settings.receiverQueueSize {
            items.append(URLQueryItem(name: "receiverQueueSize", value: "\(size)"))
        }

        var components = URLComponents(string: path)!
        components.queryItems = items
        // URLComponents leaves ":" and "/" unescaped in query values, but the
        // deadLetterTopic value is a persistent:// URI and must be escaped.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: ":", with: "%3A")
            .replacingOccurrences(of: "/", with: "%2F")
        return components.string!
    }
}
