//
//  Entity.swift
//
//
//  Created by Grady Zhuo on 2024/5/26.
//

import Foundation

public protocol Entity: AnyObject {
    associatedtype ID: Hashable
    
    var id: ID { get }
}
