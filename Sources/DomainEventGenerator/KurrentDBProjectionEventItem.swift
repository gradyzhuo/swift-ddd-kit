//
//  KurrentDBProjectionEventItem.swift
//  DDDKit
//

import Foundation

package enum KurrentDBProjectionEventItem: Codable, Equatable, Sendable {
    case plain(String)
    case custom(name: String, body: String)

    package var name: String {
        switch self {
        case .plain(let n): n
        case .custom(let n, _): n
        }
    }

    package init(from decoder: any Decoder) throws {
        // Plain string: - EventA
        if let container = try? decoder.singleValueContainer(),
           let name = try? container.decode(String.self) {
            self = .plain(name)
            return
        }
        // Mapping: - EventB: |
        //              body...
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        guard let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Expected a string or a single-key mapping for event item"))
        }
        let body = try container.decode(String.self, forKey: key)
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KurrentDBProjectionError.emptyCustomHandlerBody(eventName: key.stringValue)
        }
        self = .custom(name: key.stringValue, body: trimmed)
    }

    package func encode(to encoder: any Encoder) throws {
        switch self {
        case .plain(let name):
            var container = encoder.singleValueContainer()
            try container.encode(name)
        case .custom(let name, let body):
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            try container.encode(body, forKey: DynamicCodingKey(name))
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { self.stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
