//
//  EventDefinition.swift
//  
//
//  Created by 卓俊諺 on 2025/2/11.
//
import Foundation

package struct EventDefinitionCollection: Codable {
    let events: [Event]
    
    package init(events: [Event]){
        self.events = events
    }
    
    package init(from decoder: Decoder) throws {
        let dictionary = try [String: Event.Definition](from: decoder)
        self.events = dictionary.map {
            .init(name: $0.key, definition: $0.value)
        }
    }
        
    package func encode(to encoder: Encoder) throws {
        let dictionary = Dictionary(uniqueKeysWithValues: events.map {
            ($0.name, $0.definition)
        })
        try dictionary.encode(to: encoder)
    }
    
    func getValidEvent(kind: Event.EventKind) -> Event? {
        return events.first{
            let deprecated = $0.definition.deprecated ?? false
            return !deprecated && $0.definition.kind == kind
        }
    }
    
    func getValidEvents(kind: Event.EventKind) -> [Event] {
        return events.filter {
            let deprecated = $0.definition.deprecated ?? false
            return !deprecated && $0.definition.kind == kind
        }
    }
    
}

package struct Event {
    package var name: String
    package let definition: Definition
    
    init(name: String, definition: Definition) {
        self.name = name
        self.definition = definition
    }
}

extension Event {
    package struct Definition: Codable {
        package var migration: MigrationDefinition?
        package var kind: EventKind = .domainEvent
        package var aggregateRootId: AggregateRootIdDefinition?
        package var properties: [PropertyDefinition]?
        package var deprecated: Bool?
        
        package init(from decoder: any Decoder) throws {
        
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.migration = try container.decodeIfPresent(MigrationDefinition.self, forKey: .migration)
            let kind = try container.decodeIfPresent(EventKind.self, forKey: .kind)
            self.kind = kind ?? .domainEvent
            self.aggregateRootId = try container.decodeIfPresent(AggregateRootIdDefinition.self, forKey: .aggregateRootId)
            do {
                self.properties = try container.decodeIfPresent([PropertyDefinition].self, forKey: .properties)
            } catch {
                // Mapping format: "propertyName: Type" or legacy "propertyName: Type, index"
                // Yams preserves YAML insertion order via allKeys, so explicit indices are no longer needed.
                let orderedMap = try container.decodeIfPresent(OrderedStringMap.self, forKey: .properties)
                self.properties = orderedMap.map { map in
                    let items = map.pairs.map { key, value -> (name: String, type: String, index: Int?) in
                        let parts = value.split(separator: ",").map {
                            String($0.trimmingCharacters(in: .whitespaces))
                        }
                        let rawType = parts[0]
                        let index = parts.count > 1 ? Int(parts[1]) : nil
                        return (name: key, type: rawType, index: index)
                    }
                    // Deprecated: if any property uses ", index" syntax, sort by index and warn.
                    if items.contains(where: { $0.index != nil }) {
                        fputs("warning: [DomainEventGenerator] \"Type, index\" syntax in properties is deprecated. " +
                              "Write properties in the desired order and omit the index.\n", stderr)
                        let sorted = items.sorted {
                            guard let l = $0.index, let r = $1.index else { return false }
                            return l < r
                        }
                        return sorted.map { PropertyDefinition(name: $0.name, type: .init(rawValue: $0.type)) }
                    }
                    return items.map { PropertyDefinition(name: $0.name, type: .init(rawValue: $0.type)) }
                }
            }
            
            self.deprecated = try container.decodeIfPresent(Bool.self, forKey: .deprecated)
        }
    }
}

extension Event{
    package enum EventKind: String, Codable{
        case createdEvent
        case domainEvent
        case deletedEvent
        
        var `protocol`: String{
            switch self {
            case .createdEvent:
                "DomainEvent"
            case .deletedEvent:
                "DeletedEvent"
            case .domainEvent:
                "DomainEvent"
            }
        }
    }
}

extension Event {
    package struct AggregateRootIdDefinition: Codable {
        let alias: String
    }
}

// MARK: - Ordered mapping decoder (preserves YAML insertion order)

private struct OrderedStringMap: Decodable {
    let pairs: [(key: String, value: String)]

    private struct DynamicKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        pairs = try container.allKeys.map { key in
            (key: key.stringValue, value: try container.decode(String.self, forKey: key))
        }
    }
}
