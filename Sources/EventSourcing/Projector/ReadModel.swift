//
//  ReadModel.swift
//  DDDKit
//
//  Created by Grady Zhuo on 2026/2/9.
//

public protocol ReadModel: Codable {
    associatedtype ID: Hashable

    var id: ID { get }

    /// Name this read model is stored under (e.g. the `type` column of a Postgres
    /// snapshot table). Defaults to the Swift type name; declare a stable value so
    /// a Swift rename doesn't orphan already-stored snapshots. Changing it is a
    /// schema change — rebuild the read model afterwards.
    static var readModelTypeName: String { get }
}

extension ReadModel {
    public static var readModelTypeName: String { String(describing: Self.self) }
}
