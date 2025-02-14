//
//  EventDefinition.swift
//  
//
//  Created by 卓俊諺 on 2025/2/11.
//
import Foundation
import DDDCore

package struct EventDefinition: Codable {
    var migration: MigrationDefinition?
    var kind: EventKind = .domainEvent
    var aggregateRootId: AggregateRootIdDefinition
    var properties: [PropertyDefinition]?
    var deprecated: Bool?
    
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.migration = try container.decodeIfPresent(MigrationDefinition.self, forKey: .migration)
        let kind = try container.decodeIfPresent(EventDefinition.EventKind.self, forKey: .kind)
        self.kind = kind ?? .domainEvent
        self.aggregateRootId = try container.decode(EventDefinition.AggregateRootIdDefinition.self, forKey: .aggregateRootId)
        do{
            self.properties = try container.decodeIfPresent([PropertyDefinition].self, forKey: .properties)
        }catch {
            let convenienceProperties = try container.decodeIfPresent([String:String].self, forKey: .properties)
            self.properties = convenienceProperties.map{
                $0.map{
                    let propertyName = $0.key
                    let propertyInfos = $0.value
                                            .trimmingCharacters(in: .whitespaces)
                                            .split(separator: ",")
                    let propertyType = String(propertyInfos[0])
                    let index = String(propertyInfos[1])
                    
                    return PropertyDefinition.init(name: propertyName, type: .init(rawValue: propertyType))
                }
            }
            
            
        }
        
        self.deprecated = try container.decodeIfPresent(Bool.self, forKey: .deprecated)
    }
}

extension EventDefinition{
    enum EventKind: String, Codable{
        case createdEvent
        case domainEvent
        case deletedEvent
        
        var `protocol`: String{
            switch self {
            case .createdEvent:
                "\((any DomainEvent).self)"
            case .deletedEvent:
                "\((any DeletedEvent).self)"
            case .domainEvent:
                "\((any DomainEvent).self)"
            }
        }
    }
}

extension EventDefinition {
    package struct AggregateRootIdDefinition: Codable {
        let alias: String
    }
}
