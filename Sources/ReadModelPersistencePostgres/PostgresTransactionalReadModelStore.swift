//
//  PostgresTransactionalReadModelStore.swift
//  ReadModelPersistencePostgres
//
//  TransactionalReadModelStore impl for a Postgres snapshot table.
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

/// `TransactionalReadModelStore` impl for a Postgres snapshot table (see ``SnapshotWriteMode`` for which one).
///
/// Stateless — there's nothing to construct beyond the type. The connection
/// is supplied per-call via the `Transaction` parameter (`PostgresConnection`),
/// which arrives from `PostgresTransactionProvider.withTransaction`.
///
/// Schema/encoding mirrors `PostgresJSONReadModelStore` (one row per
/// (id, type) keyed by `Model.readModelTypeName`; data as JSONB;
/// revision as `Int64` via `bitPattern`).
public struct PostgresTransactionalReadModelStore<Model: ReadModel & Codable & Sendable>: TransactionalReadModelStore
where Model.ID == String {

    public typealias Transaction = PostgresConnection

    private let tableName: String
    private let writeMode: SnapshotWriteMode
    private let logger = Logger(label: "PostgresTransactionalReadModelStore")

    /// - Parameters:
    ///   - tableName: Base table name; the physical table depends on `writeMode`
    ///     (see ``SnapshotWriteMode``).
    ///   - writeMode: Defaults to `.monotonic`.
    public init(tableName: String = "read_model_snapshots", writeMode: SnapshotWriteMode = .monotonic) {
        self.tableName = SnapshotTable.resolve(baseName: tableName, mode: writeMode)
        self.writeMode = writeMode
    }

    public func save(readModel: Model, revision: UInt64, in transaction: PostgresConnection) async throws {
        let typeName = Model.readModelTypeName
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
            let rows = try await transaction.query(
                SnapshotUpsert.query(
                    table: tableName, id: readModel.id, typeName: typeName,
                    json: json, revision: revBits, mode: writeMode
                ),
                logger: logger
            )
            if writeMode == .monotonic, try await rows.collect().isEmpty {
                logger.debug("skipped stale snapshot write", metadata: [
                    "id": "\(readModel.id)", "type": "\(typeName)", "revision": "\(revision)",
                ])
            }
        } catch {
            throw ReadModelStoreError.saveFailed(id: readModel.id, cause: error)
        }
    }

    public func fetch(byId id: String, in transaction: PostgresConnection) async throws -> StoredReadModel<Model>? {
        let typeName = Model.readModelTypeName
        do {
            let rows = try await transaction.query("""
                SELECT data, revision FROM \(unescaped: tableName)
                WHERE id = \(id) AND type = \(typeName)
                """,
                logger: logger)

            for try await (data, revBits) in rows.decode((String, Int64).self) {
                let model = try JSONDecoder().decode(Model.self, from: Data(data.utf8))
                return StoredReadModel(readModel: model, revision: UInt64(bitPattern: revBits))
            }
            return nil
        } catch {
            throw ReadModelStoreError.fetchFailed(id: id, cause: error)
        }
    }
}
