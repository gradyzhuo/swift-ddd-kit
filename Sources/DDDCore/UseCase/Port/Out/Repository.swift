//
//  Repository.swift
//
//
//  Created by Grady Zhuo on 2024/6/2.
//

import Foundation

public protocol Repository {
    associatedtype AggregateRootType: AggregateRoot
    
}
