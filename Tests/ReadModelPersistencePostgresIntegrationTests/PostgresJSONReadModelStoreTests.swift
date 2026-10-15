// Tests/ReadModelPersistencePostgresIntegrationTests/PostgresJSONReadModelStoreTests.swift
import Testing
import Foundation
import PostgresNIO
import EventSourcing
@testable import ReadModelPersistence
@testable import ReadModelPersistencePostgres

// MARK: - Test Fixtures

private struct TestModel: ReadModel, Sendable {
    typealias ID = String
    let id: String
    var value: String
}

private struct RenamedModel: ReadModel, Sendable {
    static var readModelTypeName: String { "Stable.Name" }
    typealias ID = String
    let id: String
}

// MARK: - Test Helper

private func withStore<T>(
    writeMode: SnapshotWriteMode = .monotonic,
    _ body: (PostgresJSONReadModelStore<TestModel>) async throws -> T
) async throws -> T {
    let client = PostgresClient(configuration: .testDefault)
    let task = Task { await client.run() }
    defer { task.cancel() }

    try await PostgresReadModelMigration.createTable(
        on: client, tableName: "read_model_snapshots_test", writeMode: writeMode
    )
    let store = PostgresJSONReadModelStore<TestModel>(
        client: client, tableName: "read_model_snapshots_test", writeMode: writeMode
    )
    return try await body(store)
}

// MARK: - Tests

@Suite("PostgresJSONReadModelStore", .serialized)
struct PostgresJSONReadModelStoreTests {

    @Test("fetch 不存在的 id 回傳 nil")
    func fetchNonExistentReturnsNil() async throws {
        try await withStore { store in
            let result = try await store.fetch(byId: "ghost-\(UUID())")
            #expect(result == nil)
        }
    }

    @Test("save 後 fetch 回傳快照與正確 revision")
    func saveAndFetch() async throws {
        let id = UUID().uuidString
        try await withStore { store in
            let model = TestModel(id: id, value: "hello")
            try await store.save(readModel: model, revision: 5)

            let stored = try await store.fetch(byId: id)
            #expect(stored?.readModel.id == id)
            #expect(stored?.readModel.value == "hello")
            #expect(stored?.revision == 5)

            try await store.delete(byId: id)
        }
    }

    @Test("save 兩次覆寫快照（upsert）")
    func saveUpserts() async throws {
        let id = UUID().uuidString
        try await withStore { store in
            try await store.save(readModel: TestModel(id: id, value: "first"), revision: 1)
            try await store.save(readModel: TestModel(id: id, value: "second"), revision: 3)

            let stored = try await store.fetch(byId: id)
            #expect(stored?.readModel.value == "second")
            #expect(stored?.revision == 3)

            try await store.delete(byId: id)
        }
    }

    @Test("delete 後 fetch 回傳 nil")
    func deleteRemovesSnapshot() async throws {
        let id = UUID().uuidString
        try await withStore { store in
            try await store.save(readModel: TestModel(id: id, value: "bye"), revision: 1)
            try await store.delete(byId: id)

            let result = try await store.fetch(byId: id)
            #expect(result == nil)
        }
    }

    @Test("monotonic: an older revision is skipped, not thrown, and the newer snapshot survives")
    func monotonicSkipsOlder() async throws {
        let id = UUID().uuidString
        try await withStore(writeMode: .monotonic) { store in
            try await store.save(readModel: TestModel(id: id, value: "rev6"), revision: 6)
            try await store.save(readModel: TestModel(id: id, value: "rev5"), revision: 5)
            let stored = try await store.fetch(byId: id)
            #expect(stored?.readModel.value == "rev6")
            #expect(stored?.revision == 6)
            try await store.delete(byId: id)
        }
    }

    @Test("monotonic: an equal revision is skipped")
    func monotonicSkipsEqual() async throws {
        let id = UUID().uuidString
        try await withStore(writeMode: .monotonic) { store in
            try await store.save(readModel: TestModel(id: id, value: "first"), revision: 3)
            try await store.save(readModel: TestModel(id: id, value: "second"), revision: 3)
            #expect(try await store.fetch(byId: id)?.readModel.value == "first")
            try await store.delete(byId: id)
        }
    }

    @Test("overwrite: the last write wins even with an older revision")
    func overwriteLastWins() async throws {
        let id = UUID().uuidString
        try await withStore(writeMode: .overwrite) { store in
            try await store.save(readModel: TestModel(id: id, value: "rev6"), revision: 6)
            try await store.save(readModel: TestModel(id: id, value: "rev0"), revision: 0)
            let stored = try await store.fetch(byId: id)
            #expect(stored?.readModel.value == "rev0")
            #expect(stored?.revision == 0)
            try await store.delete(byId: id)
        }
    }

    @Test("Modes never share rows: a monotonic write is invisible to an overwrite store")
    func modesUseSeparateTables() async throws {
        let id = UUID().uuidString
        try await withStore(writeMode: .monotonic) { mono in
            try await mono.save(readModel: TestModel(id: id, value: "mono"), revision: 1)
            try await withStore(writeMode: .overwrite) { over -> Void in
                let fetched = try await over.fetch(byId: id)
                #expect(fetched == nil)
            }
            try await mono.delete(byId: id)
        }
    }

    @Test("Rows are keyed by readModelTypeName")
    func usesReadModelTypeName() async throws {
        let id = UUID().uuidString
        let client = PostgresClient(configuration: .testDefault)
        let task = Task { await client.run() }
        defer { task.cancel() }
        try await PostgresReadModelMigration.createTable(on: client, tableName: "read_model_snapshots_test")
        let store = PostgresJSONReadModelStore<RenamedModel>(client: client, tableName: "read_model_snapshots_test")
        try await store.save(readModel: RenamedModel(id: id), revision: 1)
        let rows = try await client.query(
            "SELECT type FROM read_model_snapshots_test_monotonic WHERE id = \(id)"
        )
        var types: [String] = []
        for try await type in rows.decode(String.self) { types.append(type) }
        #expect(types == ["Stable.Name"])
        try await store.delete(byId: id)
    }
}
