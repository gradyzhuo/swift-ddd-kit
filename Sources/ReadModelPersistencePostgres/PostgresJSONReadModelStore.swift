// Sources/ReadModelPersistencePostgres/PostgresJSONReadModelStore.swift
import ReadModelPersistence
import EventSourcing
import PostgresNIO
import Foundation

public struct PostgresJSONReadModelStore<Model: ReadModel & Sendable>: ReadModelStore
    where Model.ID == String
{
    private let client: PostgresClient
    private let typeName: String
    private let tableName: String

    public init(client: PostgresClient, tableName: String = "read_model_snapshots") {
        self.client = client
        self.typeName = String(describing: Model.self)
        self.tableName = tableName
    }

    public func fetch(byId id: String) async throws -> StoredReadModel<Model>? {
        do {
            let rows = try await client.query(
                "SELECT data::text, revision FROM \(unescaped: tableName) WHERE id = \(id) AND type = \(typeName)"
            )
            for try await (jsonString, revision) in rows.decode((String, Int64).self) {
                let data = Data(jsonString.utf8)
                let model = try JSONDecoder().decode(Model.self, from: data)
                return StoredReadModel(readModel: model, revision: UInt64(bitPattern: revision))
            }
            return nil
        } catch let e as ReadModelStoreError {
            throw e
        } catch {
            throw ReadModelStoreError.fetchFailed(id: id, cause: error)
        }
    }

    public func save(readModel: Model, revision: UInt64) async throws {
        do {
            let data = try JSONEncoder().encode(readModel)
            guard let jsonString = String(data: data, encoding: .utf8) else {
                throw ReadModelStoreError.saveFailed(id: readModel.id, cause: EncodingError.invalidValue(readModel, .init(codingPath: [], debugDescription: "JSON is not valid UTF-8")))
            }
            let rev = Int64(bitPattern: revision)
            try await client.query("""
                INSERT INTO \(unescaped: tableName) (id, type, data, revision, updated_at)
                VALUES (\(readModel.id), \(typeName), \(jsonString)::jsonb, \(rev), now())
                ON CONFLICT (id, type) DO UPDATE
                    SET data = \(jsonString)::jsonb, revision = \(rev), updated_at = now()
                """)
        } catch let e as ReadModelStoreError {
            throw e
        } catch {
            throw ReadModelStoreError.saveFailed(id: readModel.id, cause: error)
        }
    }

    public func delete(byId id: String) async throws {
        do {
            try await client.query(
                "DELETE FROM \(unescaped: tableName) WHERE id = \(id) AND type = \(typeName)"
            )
        } catch let e as ReadModelStoreError {
            throw e
        } catch {
            throw ReadModelStoreError.deleteFailed(id: id, cause: error)
        }
    }
}
