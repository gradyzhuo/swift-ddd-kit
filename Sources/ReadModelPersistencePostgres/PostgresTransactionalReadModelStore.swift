//
//  PostgresTransactionalReadModelStore.swift
//  ReadModelPersistencePostgres
//
//  TransactionalReadModelStore impl for `read_model_snapshots`.
//  Stateless; the connection arrives via the `Transaction` parameter.
//
//  See spec: docs/superpowers/specs/2026-04-29-transactional-subscription-runner-design.md
//

import Foundation
import Logging
import PostgresNIO
import DDDCore
import EventSourcing
import ReadModelPersistence

/// `TransactionalReadModelStore` impl for the shared `read_model_snapshots` table.
///
/// Stateless — there's nothing to construct beyond the type. The connection
/// is supplied per-call via the `Transaction` parameter (`PostgresConnection`),
/// which arrives from `PostgresTransactionProvider.withTransaction`.
///
/// Schema/encoding mirrors `PostgresJSONReadModelStore` (one row per
/// (id, type) keyed by `String(describing: Model.self)`; data as JSONB;
/// revision as `Int64` via `bitPattern`).
public struct PostgresTransactionalReadModelStore<Model: ReadModel & Codable & Sendable>: TransactionalReadModelStore
where Model.ID == String {

    public typealias Transaction = PostgresConnection

    public init() {}

    public func save(readModel: Model, revision: UInt64, in transaction: PostgresConnection) async throws {
        let typeName = String(describing: Model.self)
        let data = try JSONEncoder().encode(readModel)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ReadModelStoreError.saveFailed(
                id: readModel.id,
                cause: EncodingError.invalidValue(
                    readModel,
                    .init(codingPath: [], debugDescription: "JSON is not valid UTF-8")
                )
            )
        }
        let revBits = Int64(bitPattern: revision)

        do {
            _ = try await transaction.query("""
                INSERT INTO read_model_snapshots (id, type, data, revision, updated_at)
                VALUES (\(readModel.id), \(typeName), \(json)::jsonb, \(revBits), now())
                ON CONFLICT (id, type) DO UPDATE SET
                    data = EXCLUDED.data,
                    revision = EXCLUDED.revision,
                    updated_at = EXCLUDED.updated_at
                """,
                logger: Logger(label: "PostgresTransactionalReadModelStore"))
        } catch let e as ReadModelStoreError {
            throw e
        } catch {
            throw ReadModelStoreError.saveFailed(id: readModel.id, cause: error)
        }
    }

    public func fetch(byId id: String, in transaction: PostgresConnection) async throws -> StoredReadModel<Model>? {
        let typeName = String(describing: Model.self)
        do {
            let rows = try await transaction.query("""
                SELECT data, revision FROM read_model_snapshots
                WHERE id = \(id) AND type = \(typeName)
                """,
                logger: Logger(label: "PostgresTransactionalReadModelStore"))

            for try await (data, revBits) in rows.decode((String, Int64).self) {
                let model = try JSONDecoder().decode(Model.self, from: Data(data.utf8))
                return StoredReadModel(readModel: model, revision: UInt64(bitPattern: revBits))
            }
            return nil
        } catch let e as ReadModelStoreError {
            throw e
        } catch {
            throw ReadModelStoreError.fetchFailed(id: id, cause: error)
        }
    }
}
