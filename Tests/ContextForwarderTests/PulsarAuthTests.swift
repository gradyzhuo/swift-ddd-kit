import Foundation
import Testing
@testable import ContextForwarder

@Suite("Pulsar authentication")
struct PulsarAuthTests {

    private func config(_ auth: PulsarRESTPublisher.Authentication) -> PulsarRESTPublisher.Configuration {
        .init(baseURL: "http://localhost:8081", topic: "t", authentication: auth)
    }

    @Test("no auth sends no header")
    func noneSendsNothing() async throws {
        #expect(try await config(.none).authorizationHeader() == nil)
    }

    @Test("static token becomes a bearer header")
    func staticToken() async throws {
        #expect(try await config(.token("abc")).authorizationHeader() == "Bearer abc")
    }

    @Test("provider is called per request — rotating tokens stay fresh")
    func providerCalledEachTime() async throws {
        let counter = CallCounter()
        let configuration = config(.tokenProvider { await counter.next() })

        #expect(try await configuration.authorizationHeader() == "Bearer token-1")
        #expect(try await configuration.authorizationHeader() == "Bearer token-2")
    }

    @Test("provider failures surface to the caller")
    func providerThrows() async {
        struct Boom: Error {}
        let configuration = config(.tokenProvider { throw Boom() })
        await #expect(throws: Boom.self) { _ = try await configuration.authorizationHeader() }
    }
}

actor CallCounter {
    private var count = 0
    func next() -> String { count += 1; return "token-\(count)" }
}
