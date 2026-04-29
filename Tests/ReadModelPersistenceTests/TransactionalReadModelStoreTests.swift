import Testing
import DDDCore
import EventSourcing
import ReadModelPersistence

@Suite("TransactionalReadModelStore")
struct TransactionalReadModelStoreTests {

    private struct TestModel: ReadModel, Sendable {
        typealias ID = String
        let id: String
        var value: String
    }

    /// Stub store that records save calls per fake transaction.
    private final class StubStore: TransactionalReadModelStore, @unchecked Sendable {
        typealias Model = TestModel
        struct FakeTx: Sendable { let id: Int }

        var saves: [(modelId: String, revision: UInt64, txId: Int)] = []
        var fetched: [(modelId: String, txId: Int)] = []

        func save(readModel: TestModel, revision: UInt64, in transaction: FakeTx) async throws {
            saves.append((readModel.id, revision, transaction.id))
        }

        func fetch(byId id: String, in transaction: FakeTx) async throws -> StoredReadModel<TestModel>? {
            fetched.append((id, transaction.id))
            return nil
        }
    }

    @Test("save records in the supplied transaction")
    func saveUsesTransaction() async throws {
        let store = StubStore()
        let model = TestModel(id: "x", value: "v")
        try await store.save(readModel: model, revision: 7, in: .init(id: 42))
        #expect(store.saves.count == 1)
        #expect(store.saves[0].modelId == "x")
        #expect(store.saves[0].revision == 7)
        #expect(store.saves[0].txId == 42)
    }

    @Test("fetch records the supplied transaction")
    func fetchUsesTransaction() async throws {
        let store = StubStore()
        _ = try await store.fetch(byId: "x", in: .init(id: 99))
        #expect(store.fetched.count == 1)
        #expect(store.fetched[0].modelId == "x")
        #expect(store.fetched[0].txId == 99)
    }
}
