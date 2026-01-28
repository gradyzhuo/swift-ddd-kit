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
            do{
                self.properties = try container.decodeIfPresent([PropertyDefinition].self, forKey: .properties)
            }catch {
                let convenienceProperties = try container.decodeIfPresent([String:String].self, forKey: .properties)
                self.properties = convenienceProperties.map{
                    let infos = $0.map{
                        let propertyName = $0.key
                        let propertyInfos = $0.value
                                                .split(separator: ",")
                        let propertyType = String(propertyInfos[0].trimmingCharacters(in: .whitespaces))
                        let index = Int(propertyInfos[1].trimmingCharacters(in: .whitespaces))
                        return (name:propertyName, type: propertyType, index: index)
                    }
                    let sortedInfos = infos.sorted{
                        guard let lhsIndex = $0.index, let rhsIndex = $1.index else {
                            return false
                        }
                        return lhsIndex < rhsIndex
                    }
                    
                    return sortedInfos.map{
                        .init(name: $0.name, type: .init(rawValue: $0.type))
                    }
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
