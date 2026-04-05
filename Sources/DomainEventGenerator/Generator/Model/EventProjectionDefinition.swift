//
//  EventProjectionDefinition.swift
//  DDDKit
//
//  Created by Grady Zhuo on 2025/2/12.
//

import Foundation

package struct EventProjectionDefinition: Codable {
    package var idType: PropertyDefinition.PropertyType
    package let model: ModelKind
    package let deletedEvent: String?

    // KurrentDB projection fields
    package let category: String?
    package let idField: String?
    package let kurrentDBEvents: [KurrentDBProjectionEventItem]
    package let createdKurrentDBEvents: [KurrentDBProjectionEventItem]

    // Computed for backward compatibility with ProjectorGenerator
    package var events: [String] { kurrentDBEvents.map(\.name) }
    package var createdEvents: [String] { createdKurrentDBEvents.map(\.name) }

    package init(
        idType: PropertyDefinition.PropertyType = .string,
        model: ModelKind,
        category: String? = nil,
        idField: String? = nil,
        kurrentDBEvents: [KurrentDBProjectionEventItem] = [],
        createdKurrentDBEvents: [KurrentDBProjectionEventItem] = [],
        deletedEvent: String? = nil
    ) {
        self.idType = idType
        self.model = model
        self.category = category
        self.idField = idField
        self.kurrentDBEvents = kurrentDBEvents
        self.createdKurrentDBEvents = createdKurrentDBEvents
        self.deletedEvent = deletedEvent
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let idType = try container.decodeIfPresent(PropertyDefinition.PropertyType.self, forKey: .idType) ?? .string
        let model = try container.decode(EventProjectionDefinition.ModelKind.self, forKey: .model)
        let deletedEvent = try container.decodeIfPresent(String.self, forKey: .deletedEvent)
        let category = try container.decodeIfPresent(String.self, forKey: .category)
        let idField = try container.decodeIfPresent(String.self, forKey: .idField)

        // createdEvents: accepts String, [String], or mixed [{name: body}] list
        let createdKurrentDBEvents: [KurrentDBProjectionEventItem]
        if let single = try? container.decode(String.self, forKey: .createdEvents) {
            createdKurrentDBEvents = [.plain(single)]
        } else {
            createdKurrentDBEvents = try container.decodeIfPresent(
                [KurrentDBProjectionEventItem].self, forKey: .createdEvents) ?? []
        }

        let kurrentDBEvents = try container.decodeIfPresent(
            [KurrentDBProjectionEventItem].self, forKey: .events) ?? []

        self.init(
            idType: idType,
            model: model,
            category: category,
            idField: idField,
            kurrentDBEvents: kurrentDBEvents,
            createdKurrentDBEvents: createdKurrentDBEvents,
            deletedEvent: deletedEvent
        )
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(idType, forKey: .idType)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(deletedEvent, forKey: .deletedEvent)
        try container.encodeIfPresent(category, forKey: .category)
        try container.encodeIfPresent(idField, forKey: .idField)
        try container.encode(kurrentDBEvents, forKey: .events)
        try container.encode(createdKurrentDBEvents, forKey: .createdEvents)
    }

    private enum CodingKeys: String, CodingKey {
        case idType, model, deletedEvent, category, idField
        case events
        case createdEvents
    }
}

extension EventProjectionDefinition {
    package enum ModelKind: String, Codable {
        case aggregateRoot
        case readModel

        var `protocol`: String {
            switch self {
            case .aggregateRoot: "AggregateRoot"
            case .readModel: "ReadModel"
            }
        }
    }
}
