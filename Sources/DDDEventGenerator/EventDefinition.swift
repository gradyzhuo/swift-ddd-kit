//
//  EventDefinition.swift
//  
//
//  Created by 卓俊諺 on 2025/2/11.
//

package struct EventDefinition: Codable {
    var migration: MigrationDefinition?
    var aggregateRootId: AggregateRootIdDefinition
    var properties: [PropertyDefinition]
    var deprecated: Bool?
    
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.aggregateRootId = try container.decode(EventDefinition.AggregateRootIdDefinition.self, forKey: .aggregateRootId)
        let decodedProperties = try container.decodeIfPresent([String : EventDefinition.PropertyDefinition.Decoded].self, forKey: .properties)
        self.properties = decodedProperties.map{
            $0.map{
                PropertyDefinition(name: $0.key, type: $0.value.type.name, default: $0.value.default)
            }
        } ?? []
        self.migration = try container.decodeIfPresent(MigrationDefinition.self, forKey: .migration)
        self.deprecated = try container.decodeIfPresent(Bool.self, forKey: .deprecated)
    }
}

extension EventDefinition {
    package enum PropertyType: String, Codable {
        case int = "int"
        case string = "string"
        case float = "float"
        case double = "double"
        
        var name: String {
            return switch self {
            case .int:
                "\(Int.self)"
            case .string:
                "\(String.self)"
            case .float:
                "\(Float.self)"
            case .double:
                "\(Double.self)"
            }
        }
    }
    
    package struct AggregateRootIdDefinition: Codable {
        var alias: String
    }
    
    package struct PropertyDefinition: Codable {
        struct Decoded: Codable {
            var type: PropertyType
            var `default`: String?
        }
        var name: String
        var type: String
        var `default`: String?
        
        init(name: String, type: String, `default` defaultValue: String? = nil) {
            self.name = name
            self.type = type
            self.default = defaultValue
        }
    }
}
