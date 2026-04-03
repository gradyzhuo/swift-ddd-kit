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

// MARK: - Test Helper

private func withStore<T>(
    _ body: (PostgresJSONReadModelStore<TestModel>) async throws -> T
) async throws -> T {
    let client = PostgresClient(
        configuration: .init(
            host: "localhost",
            port: 5432,
            username: "ddd",
            password: "ddd",
            database: "ddd",
            tls: .disable
        )
    )
    let task = Task { await client.run() }
    defer { task.cancel() }

    try await client.query("""
        CREATE TABLE IF NOT EXISTS read_model_snapshots_test (
            id         TEXT        NOT NULL,
            type       TEXT        NOT NULL,
            data       JSONB       NOT NULL,
            revision   BIGINT      NOT NULL,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            PRIMARY KEY (id, type)
        )
        """)

    let store = PostgresJSONReadModelStore<TestModel>(
        client: client,
        tableName: "read_model_snapshots_test"
    )
    return try await body(store)
}

// MARK: - Tests

@Suite("PostgresJSONReadModelStore")
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
}
