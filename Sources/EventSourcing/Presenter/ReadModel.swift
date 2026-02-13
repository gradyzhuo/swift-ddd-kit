//
//  ReadModel.swift
//  DDDKit
//
//  Created by Grady Zhuo on 2026/2/9.
//

public protocol ReadModel: Codable {
    associatedtype ID: Hashable
    
    var id: ID { get }
}
