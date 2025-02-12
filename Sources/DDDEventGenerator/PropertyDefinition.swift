//
//  PropertyDefinition.swift
//  DDDKit
//
//  Created by 卓俊諺 on 2025/2/12.
//
import Foundation

package struct PropertyDefinition: Codable {
    let name: String
    let type: PropertyType
    let `default`: String?
    
    init(name: String, type: PropertyType, `default` defaultValue: String? = nil) {
        self.name = name
        self.type = type
        self.default = defaultValue
    }
    
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        
        let propertyRawValue = try container.decode(String.self, forKey: .type)
        self.type = .init(rawValue: propertyRawValue)
        self.default = try container.decodeIfPresent(String.self, forKey: .default)
    }
}

extension PropertyDefinition{
    package enum PropertyType: Codable {
        case int
        case string
        case float
        case double
        case uuid
        case date
        case custom(type: String)
        
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
            case .uuid:
                "\(UUID.self)"
            case .date:
                "\(Date.self)"
            case let .custom(type):
                type
            }
        }
        
        init(rawValue: String){
            switch rawValue {
            case "\(Self.int)", Self.int.name:
                self = .int
            case "\(Self.date)", Self.date.name:
                self = .date
            case "\(Self.string)", Self.string.name:
                self = .string
            case "\(Self.float)", Self.float.name:
                self = .float
            case "\(Self.double)", Self.double.name:
                self = .double
            case "\(Self.uuid)", Self.uuid.name:
                self = .uuid
            default:
                self = .custom(type: rawValue)
            }
        }
    }
}
