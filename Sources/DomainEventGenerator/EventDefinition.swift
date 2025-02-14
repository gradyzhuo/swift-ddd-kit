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
