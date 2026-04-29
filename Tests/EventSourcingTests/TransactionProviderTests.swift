import Testing
import EventSourcing

@Suite("TransactionProvider")
struct TransactionProviderTests {

    /// Stub provider that records lifecycle events for testing.
    private final class StubProvider: TransactionProvider, @unchecked Sendable {
        struct StubTransaction: Sendable { let id: Int }

        var nextId: Int = 0
        var commits: [Int] = []
        var rollbacks: [Int] = []

        func withTransaction<Result: Sendable>(
            _ body: (StubTransaction) async throws -> Result
        ) async throws -> Result {
            nextId += 1
            let tx = StubTransaction(id: nextId)
            do {
                let result = try await body(tx)
                commits.append(tx.id)
                return result
            } catch {
                rollbacks.append(tx.id)
                throw error
            }
        }
    }

    @Test("withTransaction commits when body returns normally")
    func commitsOnSuccess() async throws {
        let provider = StubProvider()
        let result = try await provider.withTransaction { tx in tx.id }
        #expect(result == 1)
        #expect(provider.commits == [1])
        #expect(provider.rollbacks == [])
    }

    @Test("withTransaction rolls back when body throws")
    func rollsBackOnThrow() async {
        let provider = StubProvider()
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await provider.withTransaction { _ -> Int in throw Boom() }
        }
        #expect(provider.commits == [])
        #expect(provider.rollbacks == [1])
    }

    @Test("Provider is Sendable")
    func isSendable() {
        let _: any TransactionProvider = StubProvider()
    }
}
