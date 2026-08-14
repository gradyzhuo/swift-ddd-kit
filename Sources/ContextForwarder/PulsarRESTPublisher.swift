import AsyncHTTPClient
import Foundation
import NIOCore
import PublishedLanguage

/// Publishes PL events to Pulsar over the broker's REST produce endpoint —
/// upstream contexts need ZERO Pulsar client dependency. Topics must exist;
/// call `ensureTopic()` once at startup.
public struct PulsarRESTPublisher: PublishedLanguagePublisher {

    /// How to authenticate to the broker. The framework never implements an
    /// OAuth2 flow itself — `tokenProvider` accepts whatever the host can
    /// produce (a cached client-credentials token, a rotating file, a vault
    /// lookup) and is invoked per request so rotation just works.
    public enum Authentication: Sendable {
        case none
        case token(String)
        case tokenProvider(@Sendable () async throws -> String)
    }

    public struct Configuration: Sendable {
        public let baseURL: String     // e.g. http://localhost:8081
        public let tenant: String
        public let namespace: String
        public let topic: String
        public let authentication: Authentication

        public init(baseURL: String, tenant: String = "public", namespace: String = "default", topic: String, authentication: Authentication = .none) {
            self.baseURL = baseURL
            self.tenant = tenant
            self.namespace = namespace
            self.topic = topic
            self.authentication = authentication
        }

        var producePath: String { "\(baseURL)/topics/persistent/\(tenant)/\(namespace)/\(topic)" }
        var adminPath: String { "\(baseURL)/admin/v2/persistent/\(tenant)/\(namespace)/\(topic)" }

        func authorizationHeader() async throws -> String? {
            switch authentication {
            case .none: return nil
            case .token(let token): return "Bearer \(token)"
            case .tokenProvider(let provide): return "Bearer \(try await provide())"
            }
        }
    }

    public enum PublishError: Error {
        case unexpectedStatus(UInt, body: String)
        case encodingFailed
    }

    private let httpClient: HTTPClient
    private let configuration: Configuration

    public init(httpClient: HTTPClient, configuration: Configuration) {
        self.httpClient = httpClient
        self.configuration = configuration
    }

    /// Idempotent topic creation (non-partitioned). 204 = created, 409 = exists.
    public func ensureTopic() async throws {
        var request = HTTPClientRequest(url: configuration.adminPath)
        request.method = .PUT
        if let authorization = try await configuration.authorizationHeader() {
            request.headers.add(name: "Authorization", value: authorization)
        }
        let response = try await httpClient.execute(request, timeout: .seconds(10))
        guard response.status.code == 204 || response.status.code == 409 else {
            let body = try await response.body.collect(upTo: 4096)
            throw PublishError.unexpectedStatus(response.status.code, body: String(buffer: body))
        }
        // Drain the (empty) success body so AsyncHTTPClient can reuse the connection.
        _ = try await response.body.collect(upTo: 4096)
    }

    public func publish(_ event: PublishedLanguageEvent) async throws {
        let payloadJSON = try PublishedLanguageEvent.wireEncoder.encode(event)
        guard let payloadString = String(data: payloadJSON, encoding: .utf8) else {
            throw PublishError.encodingFailed
        }
        let envelope: [String: Any] = [
            "messages": [[
                "payload": payloadString,
                "key": event.eventId,
                "properties": ["eventType": event.eventType],
            ]]
        ]
        let body = try JSONSerialization.data(withJSONObject: envelope)

        var request = HTTPClientRequest(url: configuration.producePath)
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        if let authorization = try await configuration.authorizationHeader() {
            request.headers.add(name: "Authorization", value: authorization)
        }
        // ByteBuffer(bytes:) is NIOCore; ByteBuffer(data:) lives in
        // NIOFoundationCompat, which is only implicitly available on some
        // platforms — using it broke the Linux build (Data is a Sequence<UInt8>,
        // so bytes: is the portable spelling).
        request.body = .bytes(ByteBuffer(bytes: body))

        let response = try await httpClient.execute(request, timeout: .seconds(10))
        guard (200..<300).contains(response.status.code) else {
            let responseBody = try await response.body.collect(upTo: 4096)
            throw PublishError.unexpectedStatus(response.status.code, body: String(buffer: responseBody))
        }
        // Drain the success body so AsyncHTTPClient can reuse the connection.
        _ = try await response.body.collect(upTo: 4096)
    }
}
